{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Artifact
  ( Identity (..)
  , PRNGState (..)
  , Numerics (..)
  , Manifest (..)
  , Checkpoint (..)
  , artifactVersion
  , validateCheckpoint
  , saveCheckpointAtomic
  , loadCheckpoint
  , loadCheckpointSummary
  , CorpusArtifact (..)
  , corpusArtifactVersion
  , datasetFingerprint
  , datasetFingerprintDocuments
  , validateCorpusArtifact
  , validateCorpusForTokenizer
  , saveCorpusAtomic
  , loadCorpus
  , loadCorpusWithTokenizer
  ) where

import Control.Exception (IOException, bracket, bracketOnError, try)
import Control.Monad (replicateM, unless)
import Data.Bits (shiftL, xor, (.|.))
import Data.Binary (Binary, decodeOrFail, encode, get, put)
import Data.Binary.Get (Get, getByteString, getWord8, getWord16be, getWord32be, getWord64be, runGetOrFail)
import Data.Binary.Put (putFloatbe, putWord8, putWord16be, putWord32be, putWord64be, runPut)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.List (sortOn)
import qualified Data.Set as Set
import qualified Data.Vector.Unboxed as VU
import Data.Word (Word32, Word64)
import GHC.Float (castWord32ToFloat, double2Float, float2Double)
import FormalTransformer.Config
import FormalTransformer.Data (Document (..))
import FormalTransformer.Layout (canonicalLayoutIdentity, canonicalLayoutVersion)
import FormalTransformer.Optimizer
import FormalTransformer.Tokenizer
  ( Tokenizer
  , byteTokenizerIdentity
  , tokenizerIdentityOf
  , tokenizerVocabularyFromIdentity
  , validateOrdinaryTokens
  , validateByteTokens
  )
import GHC.Generics (Generic)
import Numeric (showHex)
import System.Directory (doesFileExist, removeFile, renameFile)
import System.FilePath (takeDirectory, takeFileName)
import System.IO (Handle, IOMode (ReadMode), SeekMode (AbsoluteSeek), hClose, hFileSize, hFlush, hSeek, openBinaryTempFile, withBinaryFile)
import System.Posix.IO (OpenMode (ReadOnly), closeFd, defaultFileFlags, handleToFd, openFd)
import System.Posix.Unistd (fileSynchronise, fileSynchroniseDataOnly)

data Identity = Identity
  { modelIdentity :: !String
  , tokenizerIdentity :: !String
  , datasetIdentity :: !String
  } deriving (Eq, Show, Generic)

instance Binary Identity

data PRNGState = PRNGState !Word64 !Word64 !Word64 !Word64
  deriving (Eq, Show, Generic)

instance Binary PRNGState

data Numerics
  = Fp32IEEE
  | Tf32TensorCores
  | Bf16TensorCores
  deriving (Eq, Show)

instance Binary Numerics where
  put Fp32IEEE = putWord8 0
  put Tf32TensorCores = putWord8 1
  put Bf16TensorCores = putWord8 2
  get = do
    tag <- getWord8
    case tag of
      0 -> pure Fp32IEEE
      1 -> pure Tf32TensorCores
      2 -> pure Bf16TensorCores
      _ -> fail ("unsupported checkpoint numerics tag: " ++ show tag)

data Manifest = Manifest
  { manifestVersion :: !Word32
  , manifestConfig :: !Config
  , manifestParameterCount :: !Int
  , manifestLayoutIdentity :: !String
  , manifestLayoutVersion :: !Word32
  , manifestOptimizerConfig :: !AdamWConfig
  , manifestIdentity :: !Identity
  , manifestClipNorm :: !Double
  , manifestNumerics :: !Numerics
  } deriving (Eq, Show, Generic)

-- Versions 1 and 2 predate explicit numerics. Historical runs used IEEE f32.
instance Binary Manifest where
  put manifest = do
    put (manifestVersion manifest)
    put (manifestConfig manifest)
    put (manifestParameterCount manifest)
    put (manifestLayoutIdentity manifest)
    put (manifestLayoutVersion manifest)
    put (manifestOptimizerConfig manifest)
    put (manifestIdentity manifest)
    put (manifestClipNorm manifest)
    put (manifestNumerics manifest)
  get = do
    version <- get
    unless (version >= 1 && version <= artifactVersion)
      (fail ("unsupported checkpoint manifest version: " ++ show (version :: Word32)))
    cfg <- get
    count <- get
    layoutIdentity <- get
    layoutVersion <- get
    optimizer <- get
    identity <- get
    clip <- if version == 1 then pure 1.0 else get
    numerics <- if version <= 2 then pure Fp32IEEE else get
    pure (Manifest artifactVersion cfg count layoutIdentity layoutVersion optimizer identity clip numerics)

data Checkpoint = Checkpoint
  { checkpointManifest :: !Manifest
  , checkpointParameters :: !(VU.Vector Double)
  , checkpointOptimizer :: !AdamWState
  , checkpointBestValidationLoss :: !(Maybe Double)
  , checkpointPRNG :: !PRNGState
  } deriving (Eq, Show, Generic)

-- The pre-compact wire format. Its parameter field stays a list because that
-- is what the derived instance encodes; the conversion to the in-memory
-- representation happens at the decode boundary in loadCheckpoint.
data LegacyCheckpoint = LegacyCheckpoint
  !Manifest ![Double] !AdamWState !(Maybe Double) !PRNGState
  deriving (Generic)

instance Binary LegacyCheckpoint

data CorpusArtifact = CorpusArtifact
  { corpusVersion :: !Word32
  , corpusTokenizerIdentity :: !String
  , corpusDatasetIdentity :: !String
  , corpusDocuments :: ![Document]
  } deriving (Eq, Show, Generic)

data LegacyCorpusArtifact = LegacyCorpusArtifact
  !Word32 !String !String ![Document]
  deriving (Generic)

instance Binary LegacyCorpusArtifact

artifactVersion :: Word32
artifactVersion = 3

validateCheckpoint :: Checkpoint -> Either String Checkpoint
validateCheckpoint checkpoint = do
  let manifest = checkpointManifest checkpoint
      cfg = manifestConfig manifest
      expected = paramCount cfg
      optimizer = checkpointOptimizer checkpoint
      optimizerConfig = manifestOptimizerConfig manifest
  _ <- validateConfig cfg
  _ <- validateAdamWConfig optimizerConfig
  unless (manifestVersion manifest == artifactVersion) (Left "unsupported checkpoint version")
  unless (finite (manifestClipNorm manifest) && manifestClipNorm manifest > 0)
    (Left "manifest gradient clip must be finite and positive")
  unless (manifestParameterCount manifest == expected) (Left "manifest parameter count does not match config")
  unless (not (null (manifestLayoutIdentity manifest))) (Left "checkpoint layout identity must be non-empty")
  unless (manifestLayoutIdentity manifest == canonicalLayoutIdentity) (Left "unsupported checkpoint model layout identity")
  unless (manifestLayoutVersion manifest == canonicalLayoutVersion) (Left "unsupported checkpoint model layout version")
  unless (VU.length (checkpointParameters checkpoint) == expected) (Left "checkpoint parameter vector has wrong length")
  unless (VU.length (firstMoment optimizer) == expected && VU.length (secondMoment optimizer) == expected)
    (Left "checkpoint optimizer vectors have wrong length")
  unless (adamStep optimizer >= 0) (Left "checkpoint optimizer step is negative")
  unless (adamStep optimizer <= totalSteps optimizerConfig) (Left "checkpoint optimizer step exceeds configured total steps")
  -- Checked array by array rather than over a concatenation: the three are as
  -- long as the parameter vector, and appending them would build a third copy.
  unless (all (VU.all finite)
            [checkpointParameters checkpoint, firstMoment optimizer, secondMoment optimizer])
    (Left "checkpoint contains non-finite numbers")
  let identity = manifestIdentity manifest
  unless (all (not . null) [modelIdentity identity, tokenizerIdentity identity, datasetIdentity identity])
    (Left "checkpoint identities must be non-empty")
  case checkpointBestValidationLoss checkpoint of
    Nothing -> pure ()
    Just value -> unless (finite value && value >= 0) (Left "best validation loss must be finite and nonnegative")
  pure checkpoint
  where finite x = not (isNaN x || isInfinite x)

saveCheckpointAtomic :: FilePath -> Checkpoint -> IO (Either String ())
saveCheckpointAtomic path checkpoint = case validateCheckpoint checkpoint of
  Left message -> pure (Left message)
  Right valid -> do
    let directory = takeDirectory path
        template = takeFileName path ++ ".tmp"
    bracketOnError
      (openBinaryTempFile directory template)
      (\(temporary, handle) -> hClose handle >> removeFile temporary)
      (\(temporary, handle) -> do
        LBS.hPut handle (encodeCheckpointCompact valid)
        hFlush handle
        -- hFlush only pushes the Handle's buffer into the page cache, so the
        -- rename below was atomic against a crash but not durable against
        -- power loss -- and a rented box dies by vanishing, not by exiting.
        -- Sync the data, then sync the directory so the rename is on disk too.
        -- handleToFd takes ownership of the descriptor and leaves the Handle
        -- closed, which is why hClose is gone from here; the cleanup above
        -- stays correct because hClose on a closed Handle is a no-op.
        synchronizeHandle handle
        renameFile temporary path
        synchronizeDirectory directory)
    pure (Right ())

-- fdatasync: the file's contents, without waiting on unrelated metadata.
synchronizeHandle :: Handle -> IO ()
synchronizeHandle handle =
  bracket (handleToFd handle) closeFd fileSynchroniseDataOnly

-- A rename is only durable once the containing directory has been synced.
-- A failure here is not worth losing a completed shard over: by this point the
-- data is on disk and the rename has happened, so swallowing it leaves exactly
-- the pre-existing behaviour rather than turning a saved checkpoint into an
-- error.
synchronizeDirectory :: FilePath -> IO ()
synchronizeDirectory directory = do
  attempted <- try (bracket
    (openFd directory ReadOnly defaultFileFlags)
    closeFd
    fileSynchronise)
  case attempted of
    Left exception -> const (pure ()) (exception :: IOException)
    Right () -> pure ()

loadCheckpoint :: FilePath -> IO (Either String Checkpoint)
loadCheckpoint path = readArtifactFile "checkpoint" hint path decode
  where
    hint = "train writes one, for example: formal-transformer-gpu train CORPUS "
      ++ path ++ " STEPS [tiny|small]"
    decode bytes
      | LBS.take 4 bytes == runPut (putWord32be checkpointCompactMagic) =
          decodeCheckpointCompact bytes >>= validateCheckpoint
      | otherwise = case decodeOrFail bytes of
          Left (_, _, message) -> Left ("checkpoint decode failed: " ++ message
            ++ " (is " ++ path ++ " really a checkpoint written by train?)")
          Right (remaining, _, LegacyCheckpoint manifest params optimizer best rng)
            | not (LBS.null remaining) -> Left "checkpoint has trailing bytes"
            | otherwise ->
                validateCheckpoint (Checkpoint manifest (VU.fromList params) optimizer best rng)

checkpointCompactMagic :: Word32
checkpointCompactMagic = 0x46544332

-- Manifest and optimizer step without parsing the parameter payload: in the
-- compact layout both sit at offsets computable from the manifest's own
-- encoded length, so a small header read plus one seek answers "which weights
-- are these, how far along" in O(1) I/O on a multi-gigabyte checkpoint.
-- Legacy-format files fall back to the full parse; they are the small old
-- models, where the cost does not matter.
loadCheckpointSummary :: FilePath -> IO (Either String (Manifest, Int))
loadCheckpointSummary path = do
  present <- doesFileExist path
  if not present
    then pure (Left ("checkpoint not found: " ++ path))
    else do
      summary <- withBinaryFile path ReadMode $ \handle -> do
        prefix <- BS.hGet handle summaryPrefixBytes
        case runGetOrFail getHeader (LBS.fromStrict prefix) of
          Left _ -> pure Nothing
          Right (_, consumed, (manifest, paramLength)) -> do
            size <- hFileSize handle
            let stepOffset = fromIntegral consumed + 4 * fromIntegral paramLength :: Integer
            if stepOffset + 8 > size
              then pure (Just (Left "checkpoint is shorter than its parameter count claims"))
              else do
                hSeek handle AbsoluteSeek stepOffset
                stepBytes <- BS.hGet handle 8
                case runGetOrFail (get :: Get Int) (LBS.fromStrict stepBytes) of
                  Left (_, _, message) ->
                    pure (Just (Left ("checkpoint optimizer step unreadable: " ++ message)))
                  Right (_, _, step) -> pure (Just (Right (manifest, step)))
      case summary of
        Just result -> pure result
        Nothing -> fmap (\checkpoint ->
            ( checkpointManifest checkpoint
            , adamStep (checkpointOptimizer checkpoint)
            )) <$> loadCheckpoint path
  where
    summaryPrefixBytes = 65536
    getHeader = do
      magic <- getWord32be
      unless (magic == checkpointCompactMagic) (fail "not a compact checkpoint")
      manifest <- get
      paramLength <- getWord64be
      pure (manifest, paramLength)

encodeCheckpointCompact :: Checkpoint -> LBS.ByteString
encodeCheckpointCompact checkpoint = runPut $ do
  putWord32be checkpointCompactMagic
  put (checkpointManifest checkpoint)
  putF32Vector (checkpointParameters checkpoint)
  let optimizer = checkpointOptimizer checkpoint
  put (adamStep optimizer)
  putF32Vector (firstMoment optimizer)
  putF32Vector (secondMoment optimizer)
  put (checkpointBestValidationLoss checkpoint)
  put (checkpointPRNG checkpoint)
  where
    -- An index walk rather than a fold over a list: runPut's builder is
    -- consumed incrementally by LBS.hPut, so the file streams out without a
    -- second copy of the array ever existing.
    putF32Vector values = putWord64be (fromIntegral count) >> go 0
      where
        count = VU.length values
        go i
          | i >= count = pure ()
          | otherwise = putFloatbe (double2Float (VU.unsafeIndex values i)) >> go (i + 1)

decodeCheckpointCompact :: LBS.ByteString -> Either String Checkpoint
decodeCheckpointCompact bytes = case runGetOrFail getCheckpoint bytes of
  Left (_, _, message) -> Left ("compact checkpoint decode failed: " ++ message)
  Right (remaining, _, checkpoint)
    | not (LBS.null remaining) -> Left "checkpoint has trailing bytes"
    | otherwise -> Right checkpoint
  where
    getCheckpoint = do
      magic <- getWord32be
      unless (magic == checkpointCompactMagic) (fail "wrong compact checkpoint magic")
      manifest <- get
      params <- getF32Vector
      step <- get
      first <- getF32Vector
      second <- getF32Vector
      best <- get
      rng <- get
      pure (Checkpoint manifest params (AdamWState step first second) best rng)
    -- The payload is a contiguous run of big-endian f32, so it is taken as one
    -- ByteString and widened in place. Reading it element-wise through Get
    -- would build a boxed list first -- 4.6 GB for one 115M-parameter array,
    -- and a checkpoint holds three.
    getF32Vector = do
      declared <- getWord64be
      -- Bounded before allocating: on a corrupt length field, asking
      -- getByteString for the amount claimed would try to size a buffer from
      -- it. No array can be longer than the file that carries it.
      unless (declared <= fromIntegral (LBS.length bytes `div` 4))
        (fail "compact checkpoint array length exceeds the input")
      let count = fromIntegral declared
      payload <- getByteString (count * 4)
      pure (VU.generate count (\i -> float2Double (beFloatAt payload (i * 4))))

-- Big-endian f32 at a byte offset, reinterpreted rather than converted --
-- the same bits Data.Binary.Get.getFloatbe would have produced.
beFloatAt :: BS.ByteString -> Int -> Float
beFloatAt bytes offset = castWord32ToFloat
  (   byte offset       `shiftL` 24
  .|. byte (offset + 1) `shiftL` 16
  .|. byte (offset + 2) `shiftL` 8
  .|. byte (offset + 3) )
  where
    byte i = fromIntegral (BS.index bytes i) :: Word32

corpusArtifactVersion :: Word32
corpusArtifactVersion = 2

datasetFingerprint :: [(FilePath, BS.ByteString)] -> String
datasetFingerprint inputs = "fnv1a64-noncryptographic:" ++ pad16 (showHex digest "")
  where
    canonicalBytes = LBS.toStrict (encode (sortOn fst inputs))
    digest :: Word64
    digest = BS.foldl' (\hash byte -> (hash `xor` fromIntegral byte) * 1099511628211) 14695981039346656037 canonicalBytes
    pad16 value = replicate (16 - length value) '0' ++ value

datasetFingerprintDocuments :: String -> [Document] -> String
datasetFingerprintDocuments tokenizer documents =
  "fnv1a64-token-documents-v1:" ++ pad16 (showHex digest "")
  where
    digest :: Word64
    digest = LBS.foldlChunks hashChunk 14695981039346656037 (encode (tokenizer, documents))
    hashChunk :: Word64 -> BS.ByteString -> Word64
    hashChunk = BS.foldl' (\hash byte -> (hash `xor` fromIntegral byte) * 1099511628211)
    pad16 value = replicate (16 - length value) '0' ++ value

validateCorpusArtifact :: CorpusArtifact -> Either String CorpusArtifact
validateCorpusArtifact corpus = do
  unless (corpusVersion corpus == 1 || corpusVersion corpus == corpusArtifactVersion)
    (Left "unsupported corpus artifact version")
  unless (not (null (corpusDatasetIdentity corpus))) (Left "corpus dataset identity must be non-empty")
  let documents = corpusDocuments corpus
      identifiers = map documentId documents
  unless (all (not . null) identifiers) (Left "corpus document IDs must be non-empty")
  unless (unique identifiers) (Left "corpus document IDs must be unique")
  if corpusVersion corpus == 1
    then do
      unless (corpusTokenizerIdentity corpus == byteTokenizerIdentity)
        (Left "version-1 corpus tokenizer identity is not the fixed byte tokenizer")
      mapM_ (validateByteTokens . documentTokens) documents
    else case tokenizerVocabularyFromIdentity (corpusTokenizerIdentity corpus) of
      Nothing -> Left "version-2 corpus has an unknown tokenizer identity"
      Just vocabulary -> mapM_ (validateBounds vocabulary . documentTokens) documents
  pure corpus
  where
    validateBounds vocabulary tokens = unless
      (all (\token -> token >= 2 && token < vocabulary) tokens)
      (Left ("corpus tokens must lie in [2," ++ show (vocabulary - 1) ++ "]"))
    -- Quadratic in document count when written as a notElem recursion, which
    -- put a corpus load at 156 s for 32,000 documents against 2.2 s for 4,000.
    -- Every shard load pays it, on the training box as well as the planner.
    unique values = Set.size (Set.fromList values) == length values

validateCorpusForTokenizer :: Tokenizer -> CorpusArtifact -> Either String CorpusArtifact
validateCorpusForTokenizer tokenizer corpus = do
  valid <- validateCorpusArtifact corpus
  unless (corpusTokenizerIdentity valid == tokenizerIdentityOf tokenizer)
    (Left "corpus tokenizer identity does not match the supplied tokenizer")
  mapM_ (validateOrdinaryTokens tokenizer . documentTokens) (corpusDocuments valid)
  pure valid

saveCorpusAtomic :: FilePath -> CorpusArtifact -> IO (Either String ())
saveCorpusAtomic path corpus = case validateCorpusArtifact corpus of
  Left message -> pure (Left message)
  Right valid -> saveLazyAtomic path (encodeCorpusCompact valid) >> pure (Right ())

loadCorpus :: FilePath -> IO (Either String CorpusArtifact)
loadCorpus path = readArtifactFile "corpus" hint path decode
  where
    hint = "create one from text files with: formal-transformer prepare-bytes "
      ++ path ++ " INPUT.txt ..."
    decode bytes
      | LBS.take 4 bytes == runPut (putWord32be corpusCompactMagic) =
          decodeCorpusCompact bytes >>= validateCorpusArtifact
      | otherwise = case decodeOrFail bytes of
          Left (_, _, message) -> Left ("corpus decode failed: " ++ message
            ++ " (is " ++ path ++ " really a corpus written by prepare-bytes?)")
          Right (remaining, _, LegacyCorpusArtifact version tokenizer dataset documents)
            | not (LBS.null remaining) -> Left "corpus artifact has trailing bytes"
            | otherwise -> validateCorpusArtifact
                (CorpusArtifact version tokenizer dataset documents)

loadCorpusWithTokenizer :: Tokenizer -> FilePath -> IO (Either String CorpusArtifact)
loadCorpusWithTokenizer tokenizer path = do
  result <- loadCorpus path
  pure (result >>= validateCorpusForTokenizer tokenizer)

corpusCompactMagic :: Word32
corpusCompactMagic = 0x46544343

encodeCorpusCompact :: CorpusArtifact -> LBS.ByteString
encodeCorpusCompact corpus = runPut $ do
  putWord32be corpusCompactMagic
  put (corpusVersion corpus)
  put (corpusTokenizerIdentity corpus)
  put (corpusDatasetIdentity corpus)
  putWord64be (fromIntegral (length (corpusDocuments corpus)))
  mapM_ putDocument (corpusDocuments corpus)
  where
    putDocument document = do
      put (documentId document)
      putWord64be (fromIntegral (length (documentTokens document)))
      mapM_ (putWord16be . fromIntegral) (documentTokens document)

decodeCorpusCompact :: LBS.ByteString -> Either String CorpusArtifact
decodeCorpusCompact bytes = case runGetOrFail getCorpus bytes of
  Left (_, _, message) -> Left ("compact corpus decode failed: " ++ message)
  Right (remaining, _, corpus)
    | not (LBS.null remaining) -> Left "corpus artifact has trailing bytes"
    | otherwise -> Right corpus
  where
    getCorpus = do
      magic <- getWord32be
      unless (magic == corpusCompactMagic) (fail "wrong compact corpus magic")
      version <- get
      tokenizer <- get
      dataset <- get
      documentCount <- getWord64be
      documents <- replicateM (fromIntegral documentCount) getDocument
      pure (CorpusArtifact version tokenizer dataset documents)
    getDocument = do
      identifier <- get
      tokenCount <- getWord64be
      tokens <- replicateM (fromIntegral tokenCount) (fromIntegral <$> getWord16be)
      pure (Document identifier tokens)

-- Artifact reads fail with an actionable message instead of a bare
-- IOException: a missing path names the command that creates the artifact.
readArtifactFile
  :: String -> String -> FilePath
  -> (LBS.ByteString -> Either String a) -> IO (Either String a)
readArtifactFile kind hint path decode = do
  exists <- doesFileExist path
  if not exists
    then pure (Left (kind ++ " file not found: " ++ path ++ "\n  " ++ hint))
    else do
      -- A strict read keeps every IO failure inside this try; a lazy read
      -- would defer errors into the pure decoder.
      contents <- try (BS.readFile path)
      pure $ case contents of
        Left exception -> Left ("could not read " ++ kind ++ " file " ++ path
          ++ ": " ++ show (exception :: IOException))
        Right bytes -> decode (LBS.fromStrict bytes)

saveLazyAtomic :: FilePath -> LBS.ByteString -> IO ()
saveLazyAtomic path bytes = do
  let directory = takeDirectory path
      template = takeFileName path ++ ".tmp"
  bracketOnError
    (openBinaryTempFile directory template)
    (\(temporary, handle) -> hClose handle >> removeFile temporary)
    (\(temporary, handle) -> do
      LBS.hPut handle bytes
      hFlush handle
      hClose handle
      renameFile temporary path)
