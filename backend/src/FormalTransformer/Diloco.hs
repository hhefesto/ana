-- | Two-process data-parallel training by periodic parameter averaging
-- (DiLoCo, arXiv:2311.08105; the M=2 replica case this run uses is inside the
-- swept region of arXiv:2503.09799, and Muon as the inner optimizer is
-- arXiv:2505.23725).
--
-- Each rank trains normally on its own disjoint half of every batch for H
-- inner steps.  At the boundary the ranks average parameters and take one
-- outer Nesterov step on the /pseudo-gradient/ @theta_prev - theta_averaged@.
-- Only parameters cross between ranks; the inner optimizer moments stay local,
-- which is what makes the exchange affordable.
--
-- Why averaging rather than a per-step all-reduce, on two cards in one box:
-- the gradient already makes a full host round trip in this codebase, so the
-- whole mechanism is host vectors and files -- no NCCL bindings, no device
-- pointer plumbing, no second CUDA context.  At H=30 the exchange amortizes to
-- roughly one percent of step time.
--
-- The invariant everything else leans on: __both ranks compute bit-identical
-- outer state__.  They sum the per-rank vectors in a fixed rank order (never
-- "mine then theirs"), and the whole outer path is f32 end to end -- the same
-- precision the device buffer and the exchange files hold, so there is no
-- widening round trip whose exactness has to be assumed -- which makes the
-- average, the momentum and the new parameters agree to the bit on every
-- rank forever.  That is why the momentum is never exchanged, and why
-- 'parameterDigest' comparing equal across ranks is a real check rather than a
-- coincidence.
module FormalTransformer.Diloco
  ( DilocoConfig (..)
  , dilocoFromEnv
  , localBatchSize
  , rankWindowIndices
  , OuterState (..)
  , freshOuterState
  , outerStep
  , averageWithPeers
  , parameterDigest
  , exchangePath
  , writeMarker
  , awaitMarker
  , touchHeartbeat
  , saveOuterState
  , loadOuterState
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracketOnError)
import Control.Monad (foldM, forM_, unless, when)
import Data.Bits (xor, (.&.))
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as VSM
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word64)
import GHC.Clock (getMonotonicTime)
import GHC.Float (castFloatToWord32)
import Numeric (showHex)
import System.Directory
  ( createDirectoryIfMissing
  , doesFileExist
  , removeFile
  , renameFile
  )
import System.Environment (lookupEnv)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))
import FormalTransformer.Artifact (synchronizeDirectory, synchronizeHandle)
import System.IO
  ( BufferMode (..)
  , Handle
  , IOMode (..)
  , hClose
  , hFlush
  , hGetBuf
  , hPutBuf
  , hSetBinaryMode
  , hSetBuffering
  , openBinaryFile
  , withBinaryFile
  )
import Text.Read (readMaybe)

data DilocoConfig = DilocoConfig
  { dilocoRank :: !Int
  , dilocoWorld :: !Int
  , dilocoInner :: !Int       -- ^ H: inner steps between outer synchronizations.
  , dilocoOuterLr :: !Double
  , dilocoMomentum :: !Double
  , dilocoDir :: !FilePath
  , dilocoTimeout :: !Double  -- ^ seconds to wait for a peer before giving up.
  } deriving (Eq, Show)

-- | 'Nothing' when @DILOCO_WORLD@ is unset, and then the trainer takes exactly
-- the path it took before this module existed.  Setting @DILOCO_WORLD=1@ turns
-- the machinery on with one rank, which is degenerate but not a no-op in code:
-- at @DILOCO_OUTER_LR=1@ and @DILOCO_MOMENTUM=0@ the outer step reduces to the
-- identity, so a run configured that way must produce a byte-identical
-- checkpoint.  That is the regression test for the whole mechanism.
dilocoFromEnv :: IO (Either String (Maybe DilocoConfig))
dilocoFromEnv = do
  world <- lookupEnv "DILOCO_WORLD"
  case world of
    Nothing -> pure (Right Nothing)
    Just worldText -> do
      rankText <- maybe "0" id <$> lookupEnv "DILOCO_RANK"
      innerText <- maybe "30" id <$> lookupEnv "DILOCO_H"
      lrText <- maybe "0.7" id <$> lookupEnv "DILOCO_OUTER_LR"
      momentumText <- maybe "0.9" id <$> lookupEnv "DILOCO_MOMENTUM"
      dir <- maybe "/dev/shm/ana-diloco" id <$> lookupEnv "DILOCO_DIR"
      timeoutText <- maybe "1800" id <$> lookupEnv "DILOCO_TIMEOUT"
      pure $ do
        worldSize <- readNumber "DILOCO_WORLD" worldText
        rank <- readNumber "DILOCO_RANK" rankText
        inner <- readNumber "DILOCO_H" innerText
        lr <- readDouble "DILOCO_OUTER_LR" lrText
        momentum <- readDouble "DILOCO_MOMENTUM" momentumText
        timeout <- readDouble "DILOCO_TIMEOUT" timeoutText
        unless (worldSize >= 1) (Left "DILOCO_WORLD must be at least 1")
        unless (rank >= 0 && rank < worldSize)
          (Left "DILOCO_RANK must lie in [0, DILOCO_WORLD)")
        unless (inner >= 1) (Left "DILOCO_H must be at least 1")
        unless (momentum >= 0 && momentum < 1)
          (Left "DILOCO_MOMENTUM must lie in [0, 1)")
        -- lr = 0 freezes the parameters at theta_outer_prev forever while the
        -- inner loop keeps logging a healthy-looking loss; timeout <= 0 kills
        -- the run at the first barrier.  Both are typos, not configurations.
        unless (lr > 0) (Left "DILOCO_OUTER_LR must be positive")
        unless (timeout > 0) (Left "DILOCO_TIMEOUT must be positive")
        Right (Just (DilocoConfig rank worldSize inner lr momentum dir timeout))
  where
    readNumber name text = maybe (Left (name ++ " must be an integer")) Right
      (readMaybe text :: Maybe Int)
    readDouble name text = maybe (Left (name ++ " must be a number")) Right
      (readMaybe text :: Maybe Double)

-- | Each rank consumes a disjoint slice of the /global/ batch, so the corpus
-- is still covered exactly once per epoch and the plan's step count -- which
-- is derived from the global batch and cannot be changed mid-run -- stays
-- correct.  The global batch must divide evenly across ranks.
localBatchSize :: Maybe DilocoConfig -> Int -> Either String Int
localBatchSize Nothing globalBatch = Right globalBatch
localBatchSize (Just cfg) globalBatch
  | globalBatch `mod` dilocoWorld cfg /= 0 = Left
      ("TRAIN_BATCH " ++ show globalBatch ++ " is not divisible by DILOCO_WORLD "
        ++ show (dilocoWorld cfg))
  | otherwise = Right (globalBatch `div` dilocoWorld cfg)

-- | Which windows of the epoch permutation this rank consumes on @step@.
--
-- The global stride stays @globalBatch@ per step whatever the world size, so
-- the two ranks between them consume exactly the batch a single process would
-- have consumed, in the same order -- the corpus is still covered once per
-- epoch and the plan's step count stays honest.  Each rank simply takes a
-- disjoint contiguous block of that batch, which needs no coordination at all
-- because the permutation is a pure function of the step.
--
-- With 'Nothing' -- and equally with a world size of one -- this is exactly
-- the expression the single-process sampler has always used.
rankWindowIndices :: Maybe DilocoConfig -> Int -> Int -> Int -> [Int]
rankWindowIndices diloco globalBatch count step =
  [ (start + offset + i) `mod` count | i <- [0 .. local - 1] ]
  where
    start = ((step - 1) * globalBatch) `mod` count
    (offset, local) = case diloco of
      Nothing -> (0, globalBatch)
      Just cfg ->
        let size = globalBatch `div` dilocoWorld cfg
        in (dilocoRank cfg * size, size)

-- | @outerPrev@ is the parameter vector both ranks started the current inner
-- window from; @outerMomentum@ is the outer optimizer's Nesterov buffer.
-- Both are per-rank copies of values that are equal across ranks by
-- construction, so neither is ever sent over the wire.
data OuterState = OuterState
  { outerPrev :: !(VU.Vector Float)
  , outerMomentum :: !(VU.Vector Float)
  , outerCount :: !Int
  , outerStepAt :: !Int   -- ^ inner step the state was last written at.
  }

freshOuterState :: VU.Vector Float -> Int -> OuterState
freshOuterState parameters step =
  OuterState parameters (VU.replicate (VU.length parameters) 0) 0 step

-- | One outer step: SGD with Nesterov momentum on the pseudo-gradient.
--
-- @
--   delta = theta_prev - theta_averaged
--   m'    = mu * m + delta
--   theta = theta_prev - lr * (delta + mu * m')
-- @
--
-- At @lr = 1@ and @mu = 0@ this is @theta = theta_averaged@ exactly, which
-- with one rank is the identity -- the property the byte-identity regression
-- test relies on.
outerStep :: DilocoConfig -> OuterState -> Int -> VU.Vector Float
  -> (VU.Vector Float, OuterState)
outerStep cfg state step averaged =
  let mu = realToFrac (dilocoMomentum cfg) :: Float
      lr = realToFrac (dilocoOuterLr cfg) :: Float
      previous = outerPrev state
      delta = VU.zipWith (-) previous averaged
      momentum' = VU.zipWith (\m d -> mu * m + d) (outerMomentum state) delta
      updated = VU.zipWith3 (\p d m -> p - lr * (d + mu * m)) previous delta momentum'
  in (updated, OuterState updated momentum' (outerCount state + 1) step)

-- | Publish this rank's parameters for outer step @t@ and return the mean over
-- all ranks.  With one rank this is the identity and touches no files.
--
-- Files are written to a temporary name and renamed, so a peer that sees the
-- name sees the whole payload.  A rank deletes its own file for step @t@ only
-- once it reaches @t+1@: no peer can have advanced that far without having
-- read it, which is what makes cleanup race-free without acknowledgements.
averageWithPeers :: DilocoConfig -> Int -> Maybe Int -> VU.Vector Float
  -> IO (VU.Vector Float)
averageWithPeers cfg step retire values
  | dilocoWorld cfg <= 1 = pure values
  | otherwise = do
      createDirectoryIfMissing True (dilocoDir cfg)
      let mine = exchangePath cfg step (dilocoRank cfg)
      writeFloatVector (mine ++ ".partial") values
      renameFile (mine ++ ".partial") mine
      -- Fold in a fixed rank order -- NOT self-first -- so every rank sums the
      -- same floats in the same sequence and the mean agrees to the bit.
      let ranks = [0 .. dilocoWorld cfg - 1]
      total <- foldM (\acc peer ->
                 if peer == dilocoRank cfg
                   then pure (addInto acc values)
                   else do
                     let path = exchangePath cfg step peer
                     awaitFile cfg path
                     peerValues <- readFloatVector path (VU.length values)
                     pure (addInto acc peerValues))
                 Nothing ranks
      summed <- maybe (die "diloco: no ranks contributed") pure total
      let scale = 1 / fromIntegral (dilocoWorld cfg)
      -- Retire the previous window's file now that this one is published: no
      -- peer can be here without having read it.  Absent is fine -- after a
      -- restart the previous window belongs to a process that is gone.
      forM_ retire $ \previous -> do
        let stale = exchangePath cfg previous (dilocoRank cfg)
        there <- doesFileExist stale
        when there (removeFile stale)
      pure (VU.map (* scale) summed)
  where
    addInto Nothing v = Just v
    addInto (Just acc) v = Just (VU.zipWith (+) acc v)

-- Keyed by the inner step, which is unique and monotonic within a run.  An
-- outer-step counter would not be: a forced synchronization at a shard's last
-- step can land in the same H-window as the regular one just before it.
exchangePath :: DilocoConfig -> Int -> Int -> FilePath
exchangePath cfg step rank =
  dilocoDir cfg </> ("outer-" ++ show step ++ "-rank" ++ show rank ++ ".f32")

-- | Barrier marker, used at shard boundaries: the trainer reloads its
-- checkpoint from disk for every shard, so a rank that does not write the
-- checkpoint must not start the next shard until the rank that does has
-- finished writing it.
writeMarker :: DilocoConfig -> String -> IO ()
writeMarker cfg name = do
  createDirectoryIfMissing True (dilocoDir cfg)
  let path = dilocoDir cfg </> (name ++ ".marker")
  writeFile (path ++ ".partial") "ok\n"
  renameFile (path ++ ".partial") path

awaitMarker :: DilocoConfig -> String -> IO ()
awaitMarker cfg name = awaitFile cfg (dilocoDir cfg </> (name ++ ".marker"))

-- | Touched once per inner step, so a waiting rank can tell a peer that is
-- merely slow (heartbeat seconds old) from one that is gone (heartbeat
-- minutes old, or absent) -- which is also what lets DILOCO_TIMEOUT be chosen
-- against real step time rather than padded for the worst legitimate stall.
-- The content is the system-wide monotonic clock, comparable across the
-- ranks' processes on one box, plus the step for the human reading the report.
touchHeartbeat :: DilocoConfig -> Int -> IO ()
touchHeartbeat cfg step = do
  createDirectoryIfMissing True (dilocoDir cfg)
  let path = heartbeatPath cfg (dilocoRank cfg)
  now <- getMonotonicTime
  writeFile (path ++ ".partial") (show now ++ " " ++ show step ++ "\n")
  renameFile (path ++ ".partial") path

heartbeatPath :: DilocoConfig -> Int -> FilePath
heartbeatPath cfg rank = dilocoDir cfg </> ("heartbeat-rank" ++ show rank)

-- | One line per rank: how long ago it last completed an inner step.
heartbeatReport :: DilocoConfig -> IO String
heartbeatReport cfg = do
  now <- getMonotonicTime
  descriptions <- mapM (describe now) [0 .. dilocoWorld cfg - 1]
  pure (unwords descriptions)
  where
    describe now rank = do
      let path = heartbeatPath cfg rank
      there <- doesFileExist path
      if not there then pure ("rank" ++ show rank ++ ": no heartbeat") else do
        content <- readFile path
        pure $ case words content of
          (timeText : stepText : _)
            | Just written <- readMaybe timeText ->
                "rank" ++ show rank ++ ": step " ++ stepText ++ ", "
                  ++ show (round (now - written) :: Int) ++ "s ago"
          _ -> "rank" ++ show rank ++ ": unreadable heartbeat"

-- | Wait for a peer's file, and __die__ rather than continue if it never
-- arrives.  Silently proceeding as a lone rank would halve the effective batch
-- and quietly change the experiment, which is worse than stopping.
awaitFile :: DilocoConfig -> FilePath -> IO ()
awaitFile cfg path = do
  start <- getMonotonicTime
  let poll = do
        there <- doesFileExist path
        unless there $ do
          now <- getMonotonicTime
          when (now - start > dilocoTimeout cfg) $ do
            beats <- heartbeatReport cfg
            die ("diloco: waited " ++ show (round (now - start) :: Int)
              ++ "s for " ++ path
              ++ " -- the peer rank is not making progress; stopping rather"
              ++ " than training on a different batch than the run assumes."
              ++ " Last heartbeats: " ++ beats)
          threadDelay 50000
          poll
  poll

-- | A composite that must be equal on every rank immediately after an outer
-- step.  Three fields: an FNV-1a hash over a prime-strided sample (a prime
-- stride cannot phase-lock with any layout period, which a stride sharing a
-- factor with a slice length could), and full-vector sum-of-absolutes and
-- sum-of-squares -- the hash says WHETHER the ranks diverged, the magnitudes
-- say whether the parameters are blowing up, and both are deterministic
-- sequential folds so equal inputs give equal text.
parameterDigest :: VU.Vector Float -> String
parameterDigest values =
  let n = VU.length values
      stride = if n <= 65536 then 1 else 1021
      indices = [0, stride .. n - 1]
      step h i =
        let bits = fromIntegral (castFloatToWord32 (values VU.! i)) :: Word64
        in (h `xor` bits) * 0x100000001b3
      hashed = foldl' step 0xcbf29ce484222325 indices
      sumAbs = VU.foldl' (\a x -> a + abs (realToFrac x :: Double)) 0 values
      sumSq = VU.foldl'
        (\q x -> let d = realToFrac x :: Double in q + d * d) 0 values
  in "digest=" ++ pad (showHex (hashed .&. 0xffffffffffffffff) "")
    ++ " sumabs=" ++ show sumAbs ++ " sumsq=" ++ show sumSq
  where
    pad text = replicate (16 - length text) '0' ++ text

-- | The outer state is not part of the checkpoint format on purpose: keeping
-- it in a sidecar means @evaluate@, @check-checkpoint@ and @generate@ keep
-- reading checkpoints they already understand.  Written before the checkpoint,
-- so a checkpoint's existence implies a sidecar at least as new; a stale or
-- missing sidecar is recoverable (restart the outer optimizer) whereas a
-- corrupt checkpoint is not.
saveOuterState :: FilePath -> OuterState -> IO ()
saveOuterState path state = do
  let header = "diloco-outer-v1 " ++ show (outerStepAt state) ++ " "
        ++ show (outerCount state) ++ " "
        ++ show (VU.length (outerPrev state)) ++ "\n"
      partial = path ++ ".partial"
  -- Same discipline as saveCheckpointAtomic, for the same reason: a rented
  -- box dies by vanishing, and a rename can survive a crash that the 3.7 GB
  -- payload behind it did not -- leaving a sidecar whose header matches the
  -- checkpoint but whose vectors are garbage, which the step guard on load
  -- cannot catch.  fdatasync the payload, then sync the directory.
  -- synchronizeHandle takes ownership of the descriptor and leaves the Handle
  -- closed; the bracketOnError cleanup stays correct because hClose on a
  -- closed Handle is a no-op.
  bracketOnError
    (openBinaryFile partial WriteMode)
    (\handle -> hClose handle >> removeFile partial)
    (\handle -> do
      hSetBuffering handle (BlockBuffering Nothing)
      BSC.hPutStr handle (BSC.pack header)
      putFloats handle (outerPrev state)
      putFloats handle (outerMomentum state)
      hFlush handle
      synchronizeHandle handle
      renameFile partial path
      synchronizeDirectory (takeDirectory path))

-- | 'Nothing' when the sidecar is absent or does not describe this run; the
-- caller then restarts the outer optimizer from the current parameters, which
-- costs one window of momentum and nothing else.
loadOuterState :: FilePath -> Int -> IO (Maybe OuterState)
loadOuterState path expectedLength = do
  there <- doesFileExist path
  if not there then pure Nothing else withBinaryFile path ReadMode $ \handle -> do
    hSetBinaryMode handle True
    headerLine <- BSC.hGetLine handle
    case words (BSC.unpack headerLine) of
      ["diloco-outer-v1", stepText, countText, lengthText]
        | Just step <- readMaybe stepText
        , Just count <- readMaybe countText
        , Just len <- readMaybe lengthText
        , len == expectedLength -> do
            previous <- getFloats handle len
            momentum <- getFloats handle len
            pure (Just (OuterState previous momentum count step))
      _ -> pure Nothing

-- Raw native-endian f32.  These are same-host IPC and restart files, never
-- artifacts that move between machines, so there is no portable encoding to
-- pay for -- and the vectors are f32 in memory too, so nothing is converted
-- in either direction.
writeFloatVector :: FilePath -> VU.Vector Float -> IO ()
writeFloatVector path values =
  withBinaryFile path WriteMode $ \handle -> do
    hSetBuffering handle (BlockBuffering Nothing)
    putFloats handle values

readFloatVector :: FilePath -> Int -> IO (VU.Vector Float)
readFloatVector path expected =
  withBinaryFile path ReadMode $ \handle -> do
    hSetBinaryMode handle True
    getFloats handle expected

putFloats :: Handle -> VU.Vector Float -> IO ()
putFloats handle values = do
  let floats = VS.convert values :: VS.Vector Float
  VS.unsafeWith floats $ \ptr -> hPutBuf handle ptr (VS.length floats * 4)

getFloats :: Handle -> Int -> IO (VU.Vector Float)
getFloats handle count = do
  buffer <- VSM.new count :: IO (VSM.IOVector Float)
  got <- VSM.unsafeWith buffer $ \ptr -> hGetBuf handle ptr (count * 4)
  when (got /= count * 4) $
    die ("diloco: expected " ++ show (count * 4) ++ " bytes of f32, read "
      ++ show got ++ " -- a truncated exchange or sidecar file")
  frozen <- VS.unsafeFreeze buffer
  pure (VU.convert frozen)
