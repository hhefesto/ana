module Main (main) where

import Control.Exception (bracket)
import Control.Monad (foldM, forM_, unless, when)
import Control.Parallel.Strategies (parListChunk, rdeepseq, using)
import qualified Data.ByteString as BS
import Data.Bits (rotateL, shiftL, shiftR, xor)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import qualified Data.IntMap.Strict as IntMap
import Data.List (foldl', isSuffixOf, sortOn)
import Data.Time (defaultTimeLocale, formatTime, getZonedTime)
import Data.Word (Word64)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Vector as V
import qualified Data.Vector.Unboxed as U
import qualified Data.Vector.Unboxed.Mutable as UM
import FormalTransformer.Artifact
import FormalTransformer.Bigram
import FormalTransformer.Config
import FormalTransformer.Data
import FormalTransformer.Layout
import FormalTransformer.Model (ActStats (..), BlockStats (..), fullSequenceStats)
import FormalTransformer.Optimizer
import FormalTransformer.Tokenizer
import FutharkKernels
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (copyFile, doesFileExist)
import System.Environment (getArgs, lookupEnv, setEnv)
import System.Mem (performGC)
import System.Exit (die)
import System.IO (BufferMode (LineBuffering), hFlush, hPutStrLn, hSetBuffering, stderr, stdout)
import System.IO.Unsafe (unsafePerformIO)
import Text.Printf (printf)
import Text.Read (readMaybe)

modelId :: Config -> String
modelId cfg = "formal-transformer-futhark-hybrid-gla-v2:" ++ show cfg

-- Schedule experiment overrides; the defaults are the historical constants.
-- TRAIN_LR / TRAIN_WD / TRAIN_WARMUP change training semantics — use them
-- only for stability probes, and record them with any published run.
{-# NOINLINE envFloat #-}
envFloat :: String -> Double -> Double
envFloat name fallback = unsafePerformIO $
  maybe fallback (\raw -> maybe fallback id (readMaybe raw)) <$> lookupEnv name

{-# NOINLINE envInt #-}
envInt :: String -> Int -> Int
envInt name fallback = unsafePerformIO $
  maybe fallback (\raw -> maybe fallback id (readMaybe raw)) <$> lookupEnv name

optimizerFor :: Int -> AdamWConfig
optimizerFor steps = AdamWConfig
  (envFloat "TRAIN_LR" 3e-4) 0.9 0.999 1e-8
  (envFloat "TRAIN_WD" 0.01)
  (min (envInt "TRAIN_WARMUP" 100) steps) steps

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  setEnv "TZ" "America/Mexico_City"
  args <- getArgs
  case args of
    ["inspect"] -> inspect tinyPreset
    ["inspect", size] -> chooseConfig size >>= inspect
    ["warm-context"] -> warmContext tinyPreset
    ["warm-context", size] -> chooseConfig size >>= warmContext
    ["train", corpus, checkpoint, stepsText] -> do
      spec <- parseTarget stepsText
      train corpus checkpoint (Standalone spec) tinyPreset
    ["train", corpus, checkpoint, stepsText, size] -> do
      spec <- parseTarget stepsText
      cfg <- chooseConfig size
      train corpus checkpoint (Standalone spec) cfg
    ["train-segment", corpus, checkpoint, totalText, startText, endText,
      offsetText, globalIdentity, expectedCorpusIdentity, size] -> do
      total <- parsePositive "GLOBAL_TOTAL_STEPS" totalText
      start <- parseNonnegative "SEGMENT_START_STEP" startText
      end <- parsePositive "SEGMENT_END_STEP" endText
      offset <- parseWord64 "DOCUMENT_OFFSET" offsetText
      cfg <- chooseConfig size
      train corpus checkpoint
        (Segment total start end offset globalIdentity expectedCorpusIdentity) cfg
    ["train-plan", plan, runDir, checkpoint, size] -> do
      cfg <- chooseConfig size
      trainPlan plan runDir checkpoint size cfg
    ["generate", checkpoint, text] -> generate checkpoint text 128
    ["generate", checkpoint, text, budgetText] -> parseNonnegative "MAXTOKENS" budgetText >>= generate checkpoint text
    ["check-checkpoint", checkpoint] -> checkCheckpoint checkpoint
    ["evaluate", checkpoint, corpus] -> evaluate checkpoint corpus
    ["bench", corpus] -> bench corpus tinyPreset
    ["bench", corpus, size] -> chooseConfig size >>= bench corpus
    ["act-stats", corpus, checkpoint] -> actStats corpus checkpoint bpe10mPreset
    ["act-stats", corpus, checkpoint, size] -> chooseConfig size >>= actStats corpus checkpoint
    ["head-probe", corpus] -> headProbe corpus bpe10mPreset
    ["head-probe", corpus, size] -> chooseConfig size >>= headProbe corpus
    ["grad-compare", gradFile, tokensFile] -> gradCompare gradFile tokensFile bpe10mPreset
    ["grad-compare", gradFile, tokensFile, size] -> chooseConfig size >>= gradCompare gradFile tokensFile
    ["head-path-probe"] -> headPathProbe bpe10mPreset
    ["head-path-probe", size] -> chooseConfig size >>= headPathProbe
    _ -> die "usage: formal-transformer-gpu inspect [tiny|small|bpe10m|bpe100m|gla-small|gla] | warm-context [tiny|small|bpe10m|bpe100m|gla-small|gla] | train CORPUS CHECKPOINT (STEPS|epoch) [tiny|small|bpe10m|bpe100m|gla-small|gla] | train-segment CORPUS CHECKPOINT GLOBAL_TOTAL START END DOCUMENT_OFFSET GLOBAL_ID EXPECTED_CORPUS_ID SIZE | train-plan PLAN RUN_DIR CHECKPOINT SIZE | generate CHECKPOINT TEXT [MAXTOKENS] | check-checkpoint CHECKPOINT | evaluate CHECKPOINT CORPUS | bench CORPUS [tiny|small|bpe10m|bpe100m|gla-small|gla]"

chooseConfig :: String -> IO Config
chooseConfig "tiny" = pure tinyPreset
chooseConfig "small" = pure smallPreset
chooseConfig "small4" = pure small4Preset
chooseConfig "bpe10m" = pure bpe10mPreset
chooseConfig "bpe100m" = pure bpe100mPreset
chooseConfig "gla-small" = pure glaSmallPreset
chooseConfig "gla" = pure glaPreset
chooseConfig value = die ("unknown model size: " ++ value ++ " (expected tiny, small, small4, bpe10m, bpe100m, gla-small, or gla)")

inspect :: Config -> IO ()
inspect cfg = either die (mapM_ print) (namedLayout cfg) >> do
  putStrLn ("config: " ++ show cfg)
  putStrLn ("parameters: " ++ show (paramCount cfg))

-- Force backend context creation without loading data or taking an optimizer
-- step.  GPU backends compile and cache their generated program here, so a
-- subsequent gate can measure execution independently of cold NVRTC/OpenCL
-- compilation.
warmContext :: Config -> IO ()
warmContext cfg = do
  gpu <- gpuConfigIO cfg >>= either die pure
  withContext $ \ctx -> do
    count <- futharkParameterCount ctx gpu
    when (count /= fromIntegral (paramCount cfg)) $
      die "Futhark parameter count disagrees with the host configuration"
    putStrLn ("context ready: " ++ show cfg ++ " (" ++ show count ++ " parameters)")

-- Activation-statistics diagnostic: run the pure reference forward
-- (FormalTransformer.Model.fullSequenceStats) over the first ACT_WINDOWS
-- training windows at a checkpoint's parameters and print per-layer
-- statistics.  CPU-only and backend-independent: every backend conforms
-- to this reference, so the numbers describe the model, not a runtime.
actStats :: FilePath -> FilePath -> Config -> IO ()
actStats corpusPath checkpointPath cfg = do
  windowsWanted <- positiveEnv "ACT_WINDOWS" 4
  corpus <- loadCorpus corpusPath >>= either die pure
  split <- either die pure (trainingSequencesFrom 0 cfg (corpusDocuments corpus))
  let windows = map (map fromIntegral) (take windowsWanted (training split)) :: [[Int]]
  when (null windows) (die "corpus yields no full training windows")
  checkpoint <- loadCheckpoint checkpointPath >>= either die pure
  let manifest = checkpointManifest checkpoint
  when (manifestConfig manifest /= cfg) (die
    ("checkpoint config " ++ show (manifestConfig manifest)
      ++ " does not match requested size " ++ show cfg))
  let params = U.toList (checkpointParameters checkpoint)
      step = adamStep (checkpointOptimizer checkpoint)
  results <- mapM (either die pure . fullSequenceStats cfg params) windows
  let mean xs = sum xs / fromIntegral (length xs) :: Double
      header = "act step=" ++ show step ++ " windows=" ++ show (length results)
  putStrLn (header
    ++ printf " loss=%.6f" (mean (map actLoss results))
    ++ printf " p_target=%.6g" (mean (map actPTarget results))
    ++ printf " logit_rms=%.6g" (mean (map actLogitRms results))
    ++ printf " logit_max=%.6g" (maximum (map actLogitMax results))
    ++ printf " embed_rms=%.6g" (mean (map actEmbeddingRms results)))
  let layers = length (actBlocks (head results))
      layerLine i =
        let blocks = map ((!! i) . actBlocks) results
            b0 = head blocks
            (rf, rm, rl) = unzip3 (map blockStatsResidual blocks)
            alphaText = case blockStatsAlpha b0 of
              Nothing -> ""
              Just _ ->
                let picks f = mean [f a | Just a <- map blockStatsAlpha blocks]
                in printf " alpha_mean=%.4f" (picks (\(a, _, _) -> a))
                  ++ printf " alpha_geo=%.4f" (picks (\(_, g, _) -> g))
                  ++ printf " alpha_open=%.4f" (picks (\(_, _, o) -> o))
        in header ++ " layer=" ++ show i
          ++ " kind=" ++ blockStatsKind b0
          ++ printf " res_first=%.5g" (mean rf)
          ++ printf " res_mid=%.5g" (mean rm)
          ++ printf " res_last=%.5g" (mean rl)
          ++ printf " att_rms=%.5g" (mean (map blockStatsAttended blocks))
          ++ printf " cos_embed=%.4f" (mean (map blockStatsCosEmbed blocks))
          ++ alphaText
  mapM_ (putStrLn . layerLine) [0 .. layers - 1]

-- B0 head-only probe.  With an identity trunk (INIT_ZERO_OUT) the model is
-- context-free, so the whole corpus collapses to bigram counts; this trains
-- that collapsed problem directly on CPU with the production init, schedule,
-- and AdamW, in minutes.  The tied arm is exactly the FREEZE_TRUNK model.
-- Because the tied logit matrix is a per-row-rescaled symmetric Gram matrix
-- (z ∝ E·diag(g)·Eᵀ), the skew part of the bigram statistics is
-- unrepresentable when tied; the untied arm changes only the output matrix,
-- so the pair measures exactly that representational gap.  Also prints the
-- exact unigram/bigram entropy floors of the corpus.
--   HEAD_STEPS (500), HEAD_CONTEXTS (64) sampled contexts per step
--   HEAD_TIE=0   untied output matrix   HEAD_MIX=1  fixed per-context hash
--   offset added pre-norm (breaks the Gram symmetry like a live trunk)
--   HEAD_OPT=sgd plain SGD; TRAIN_LR/TRAIN_WD/TRAIN_WARMUP and
--   INIT_SCALE/INIT_KIND as in training
headProbe :: FilePath -> Config -> IO ()
headProbe corpusPath cfg = do
  steps <- positiveEnv "HEAD_STEPS" 500
  contextsPerStep <- positiveEnv "HEAD_CONTEXTS" 64
  tied <- (/= Just "0") <$> lookupEnv "HEAD_TIE"
  mixed <- (== Just "1") <$> lookupEnv "HEAD_MIX"
  onehot <- (== Just "1") <$> lookupEnv "HEAD_ONEHOT"
  optName <- maybe "adamw" id <$> lookupEnv "HEAD_OPT"
  corpus <- loadCorpus corpusPath >>= either die pure
  split <- either die pure (trainingSequencesFrom 0 cfg (corpusDocuments corpus))
  let vocab = vocabSize cfg
      d = modelDim cfg
      windows = training split
  when (null windows) (die "corpus yields no full training windows")
  countsM <- UM.replicate (vocab * vocab) (0 :: Int)
  mapM_ (\window -> mapM_ (\(a, b) ->
          UM.unsafeModify countsM (+ 1) (fromIntegral a * vocab + fromIntegral b))
        (zip window (drop 1 window)))
    windows
  counts <- U.unsafeFreeze countsM
  let contextTotals = U.generate vocab (\a -> U.sum (U.unsafeSlice (a * vocab) vocab counts))
      total = U.sum contextTotals
      cumulative = U.scanl1 (+) contextTotals
      totalD = fromIntegral total :: Double
      targetTotals = U.create $ do
        acc <- UM.replicate vocab (0 :: Int)
        let go i = when (i < vocab * vocab) $ do
              let c = counts U.! i
              when (c /= 0) (UM.unsafeModify acc (+ c) (i `mod` vocab))
              go (i + 1)
        go 0
        pure acc
      unigramEntropy = negate (U.sum (U.map (\t -> if t == 0 then 0
        else let p = fromIntegral t / totalD in p * log p) targetTotals))
      bigramEntropy = negate (U.ifoldl' (\acc i c -> if c == 0 then acc
        else let a = i `div` vocab
                 ca = fromIntegral (contextTotals U.! a) :: Double
             in acc + (fromIntegral c / totalD) * log (fromIntegral c / ca)) 0 counts)
  when (total <= 0) (die "corpus yields no bigram pairs")
  logTraining ("head-probe tied=" ++ show tied ++ " mixed=" ++ show mixed
    ++ " onehot=" ++ show onehot
    ++ " opt=" ++ optName ++ " steps=" ++ show steps
    ++ " contexts_per_step=" ++ show contextsPerStep
    ++ " pairs=" ++ show total
    ++ printf " unigram_entropy=%.6f" unigramEntropy
    ++ printf " bigram_entropy=%.6f" bigramEntropy
    ++ " uniform=" ++ printf "%.6f" (log (fromIntegral vocab) :: Double))
  -- parameters, production init: embedding at layout offset 0, so the tied
  -- arm reproduces the trainer's embedding values exactly
  embed <- U.thaw (U.generate (vocab * d) (\i -> initNoise (i + 1)))
  output <- if tied then pure Nothing
    else Just <$> U.thaw (U.generate (vocab * d) (\i -> initNoise (vocab * d + i + 1)))
  let momentSize = vocab * d
  mE <- UM.replicate momentSize (0 :: Double)
  vE <- UM.replicate momentSize (0 :: Double)
  mO <- UM.replicate (if tied then 0 else momentSize) (0 :: Double)
  vO <- UM.replicate (if tied then 0 else momentSize) (0 :: Double)
  gradE <- UM.replicate momentSize (0 :: Double)
  gradO <- UM.replicate (if tied then 0 else momentSize) (0 :: Double)
  let mixOffset = if mixed
        then U.generate (vocab * d) (\i -> 0.02 * hashNoise (0x51A00000 + i))
        else U.replicate (vocab * d) 0
      optCfg = optimizerFor steps
      sampleContext k =
        let u = (hashNoise (0x5EED0000 + k) + 1) / 2
            r = min (total - 1) (max 0 (floor (u * totalD)))
            search lo hi
              | lo >= hi = lo
              | otherwise =
                  let mid = (lo + hi) `div` 2
                  in if cumulative U.! mid > r then search lo mid else search (mid + 1) hi
        in search 0 (vocab - 1)
      -- One-hot arm: draw the target from the bigram conditional of `a`,
      -- like the trainer's token-level CE (the full-row default is the
      -- exact expectation of this).
      sampleTarget a k =
        let ca = contextTotals U.! a
            u = (hashNoise (0x7A9E7000 + k) + 1) / 2
            r = min (ca - 1) (max 0 (floor (u * fromIntegral ca)))
            go w acc
              | w >= vocab = vocab - 1
              | acc + c > r = w
              | otherwise = go (w + 1) (acc + c)
              where c = counts U.! (a * vocab + w)
        in go 0 0
      forward eSnap outMat a =
        let x = U.generate d (\j -> eSnap U.! (a * d + j) + mixOffset U.! (a * d + j))
            s = sqrt (U.sum (U.map (\xv -> xv * xv) x) / fromIntegral d + 1e-5)
            h = U.map (/ s) x
            z = U.generate vocab (\w -> U.sum (U.zipWith (*) (U.unsafeSlice (w * d) d outMat) h))
            zMax = U.maximum z
            expz = U.map (\zi -> exp (zi - zMax)) z
            zSum = U.sum expz
            logZ = zMax + log zSum
            ca = fromIntegral (contextTotals U.! a) :: Double
            pData = U.generate vocab (\w -> fromIntegral (counts U.! (a * vocab + w)) / ca)
            rowCE = logZ - U.sum (U.zipWith (*) pData z)
        in (x, s, h, z, expz, zSum, pData, rowCE)
      contextLoss eSnap outMat a =
        let (_, _, _, _, _, _, _, rowCE) = forward eSnap outMat a in rowCE
      processContext eSnap outMat step k = do
        let a = sampleContext (step * 1048576 + k)
            (x, s, h, z, expz, zSum, pData, rowCEFull) = forward eSnap outMat a
            (dz, rowCE) =
              if onehot
                then let w0 = sampleTarget a (step * 1048576 + k)
                         logZ = U.maximum z + log zSum
                     in ( U.generate vocab (\w ->
                            expz U.! w / zSum - (if w == w0 then 1 else 0))
                        , logZ - z U.! w0 )
                else ( U.generate vocab (\w -> expz U.! w / zSum - pData U.! w)
                     , rowCEFull )
            uVec = U.generate d (\j -> U.sum (U.generate vocab (\w ->
                     dz U.! w * outMat U.! (w * d + j))))
            uDotX = U.sum (U.zipWith (*) uVec x)
            dn = fromIntegral d :: Double
            dx = U.generate d (\j -> uVec U.! j / s - (x U.! j) * uDotX / (dn * s * s * s))
            gradTarget = if tied then gradE else gradO
            accumRow w dzw =
              let base = w * d
                  go j = when (j < d) $ do
                    UM.unsafeModify gradTarget (+ dzw * (h U.! j)) (base + j)
                    go (j + 1)
              in go 0
        U.imapM_ accumRow dz
        U.imapM_ (\j dxj -> UM.unsafeModify gradE (+ dxj) (a * d + j)) dx
        pure rowCE
      applyUpdate step lr params moments1 moments2 grads =
        let stepD = fromIntegral step :: Double
            b1c = 1 - beta1 optCfg ** stepD
            b2c = 1 - beta2 optCfg ** stepD
            wd = weightDecay optCfg
            scale = 1 / fromIntegral contextsPerStep
            go j = when (j < momentSize) $ do
              g <- (* scale) <$> UM.unsafeRead grads j
              p <- UM.unsafeRead params j
              p' <- if optName == "sgd"
                then pure (p - lr * (g + wd * p))
                else do
                  m0 <- UM.unsafeRead moments1 j
                  v0 <- UM.unsafeRead moments2 j
                  let m1 = beta1 optCfg * m0 + (1 - beta1 optCfg) * g
                      v1 = beta2 optCfg * v0 + (1 - beta2 optCfg) * g * g
                  UM.unsafeWrite moments1 j m1
                  UM.unsafeWrite moments2 j v1
                  pure (p - lr * (m1 / b1c / (sqrt (v1 / b2c) + adamEpsilon optCfg) + wd * p))
              UM.unsafeWrite params j p'
              go (j + 1)
        in go 0
      runStep ema step = do
        eSnap <- U.freeze embed
        oSnap <- traverse U.freeze output
        let outMat = maybe eSnap id oSnap
        UM.set gradE 0
        when (not tied) (UM.set gradO 0)
        losses <- mapM (processContext eSnap outMat step) [0 .. contextsPerStep - 1]
        let loss = sum losses / fromIntegral (length losses)
            ema' = case ema of
              Nothing -> loss
              Just previous -> trainLossEmaDecayD * previous + (1 - trainLossEmaDecayD) * loss
            lr = learningRate optCfg step
        applyUpdate step lr embed mE vE gradE
        when (not tied) (applyUpdate step lr (maybe (error "untied") id output) mO vO gradO)
        when (step `mod` 25 == 0 || step == 1) $
          logTraining ("head step=" ++ show step ++ "/" ++ show steps
            ++ " lr=" ++ printf "%.6g" lr
            ++ " loss=" ++ printf "%.6f" loss
            ++ " loss_ema=" ++ printf "%.6f" ema')
        pure (Just ema')
      trainLossEmaDecayD = 0.9 :: Double
  _ <- foldM runStep Nothing [1 .. steps]
  -- exact count-weighted final loss over every context with mass
  eSnap <- U.freeze embed
  oSnap <- traverse U.freeze output
  let outMat = maybe eSnap id oSnap
      finalLoss = sum
        [ (fromIntegral ca / totalD) * contextLoss eSnap outMat a
        | a <- [0 .. vocab - 1]
        , let ca = contextTotals U.! a
        , ca > 0
        ]
  logTraining ("head final full_loss=" ++ printf "%.6f" finalLoss
    ++ printf " vs_bigram_floor=%.6f" (finalLoss - bigramEntropy)
    ++ printf " vs_unigram=%.6f" (finalLoss - unigramEntropy))

-- Compare a runtime-dumped step-1 gradient (DUMP_GRAD_VECTOR=path, which
-- also writes path.tokens) against the exact f64 gradient of the same batch
-- under the FREEZE_TRUNK + INIT_ZERO_OUT reading: the trunk is exactly the
-- identity in both directions, so the model is embedding -> rms -> tied
-- logits and the full gradient is computable in closed form.  Prints loss
-- and cosine/norm diagnostics for the embedding slice, split into the
-- output-row (head) part and the input (dx) part.
gradCompare :: FilePath -> FilePath -> Config -> IO ()
gradCompare gradFile tokensFile cfg = do
  let vocab = vocabSize cfg
      d = modelDim cfg
      embLen = vocab * d
      dn = fromIntegral d :: Double
  gradLines <- lines <$> readFile gradFile
  let (embLines, trunkLines) = splitAt embLen gradLines
      runtimeEmb = U.fromListN embLen (map read embLines) :: U.Vector Double
      trunkSq = foldl' (\acc s -> let v = read s :: Double in acc + v * v) 0 trunkLines
  when (U.length runtimeEmb /= embLen)
    (die ("gradient file has fewer than " ++ show embLen ++ " values"))
  windows <- map (map read . words) . lines <$> readFile tokensFile :: IO [[Int]]
  -- GRAD_PAIRING picks the (context, target) reading used by the oracle:
  --   next (default) — the true objective, target is the following token
  --   self           — target is the context token itself
  --   prev           — roles swapped (predict the previous token)
  -- Comparing the runtime dump against each fingerprints misalignment bugs.
  pairing <- maybe "next" id <$> lookupEnv "GRAD_PAIRING"
  let pairs = case pairing of
        "self" -> concatMap (\w -> [ (a, a) | a <- take (length w - 1) w ]) windows
        "prev" -> concatMap (\w -> zip (drop 1 w) w) windows
        _ -> concatMap (\w -> zip w (drop 1 w)) windows
      totalPairs = length pairs
  when (totalPairs == 0) (die "tokens file yields no training pairs")
  putStrLn ("grad-compare pairing=" ++ pairing)
  let embed = U.generate embLen (\i -> initNoise (i + 1))
      scale = 1 / fromIntegral totalPairs :: Double
      contexts = IntMap.toList (IntMap.fromListWith (IntMap.unionWith (+))
        [ (a, IntMap.singleton b (1 :: Int)) | (a, b) <- pairs ])
  gradHead <- UM.replicate embLen (0 :: Double)
  gradDx <- UM.replicate embLen (0 :: Double)
  gainBar <- UM.replicate d (0 :: Double)
  lossAcc <- newIORef (0 :: Double)
  forM_ contexts $ \(a, targets) -> do
    let cnt = fromIntegral (sum (IntMap.elems targets)) :: Double
        x = U.slice (a * d) d embed
        s = sqrt (U.sum (U.map (\xv -> xv * xv) x) / dn + 1e-5)
        h = U.map (/ s) x
        z = U.generate vocab (\w -> U.sum (U.zipWith (*) (U.slice (w * d) d embed) h))
        zMax = U.maximum z
        expz = U.map (\zi -> exp (zi - zMax)) z
        zSum = U.sum expz
        logZ = zMax + log zSum
        dzTot = U.generate vocab (\w ->
          cnt * (expz U.! w / zSum)
            - fromIntegral (IntMap.findWithDefault 0 w targets))
        uVec = U.generate d (\j -> U.sum (U.generate vocab (\w ->
          dzTot U.! w * embed U.! (w * d + j))))
        uDotX = U.sum (U.zipWith (*) uVec x)
        dx = U.generate d (\j -> uVec U.! j / s - (x U.! j) * uDotX / (dn * s * s * s))
    modifyIORef' lossAcc (+ (cnt * logZ - sum
      [ fromIntegral c * (z U.! w) | (w, c) <- IntMap.toList targets ]))
    U.imapM_ (\w dzw -> when (dzw /= 0) $
      let base = w * d
          go j = when (j < d) $ do
            UM.unsafeModify gradHead (+ scale * dzw * (h U.! j)) (base + j)
            go (j + 1)
      in go 0) dzTot
    U.imapM_ (\j dxj -> UM.unsafeModify gradDx (+ scale * dxj) (a * d + j)) dx
    -- final_rms gain gradient: out = x_hat * gain (gain = 1 at init), so
    -- dL/dgain[j] = sum over positions of x_hat[j] * uVec[j].
    forM_ [0 .. d - 1] $ \j ->
      UM.unsafeModify gainBar (+ scale * (h U.! j) * (uVec U.! j)) j
  lossTotal <- readIORef lossAcc
  headV <- U.unsafeFreeze gradHead
  dxV <- U.unsafeFreeze gradDx
  let oracle = U.zipWith (+) headV dxV
      dot2 u v = U.sum (U.zipWith (*) u v)
      norm2 u = sqrt (dot2 u u)
      cosine u v = let nu = norm2 u; nv = norm2 v
                   in if nu == 0 || nv == 0 then 0 else dot2 u v / (nu * nv)
  putStrLn ("grad-compare pairs=" ++ show totalPairs
    ++ " windows=" ++ show (length windows)
    ++ printf " oracle_loss=%.6f" (lossTotal * scale))
  putStrLn (printf "runtime_norm=%.6g oracle_norm=%.6g ratio=%.4f trunk_norm=%.6g"
    (norm2 runtimeEmb) (norm2 oracle) (norm2 runtimeEmb / norm2 oracle) (sqrt trunkSq))
  putStrLn (printf "cos(runtime, oracle)=%.6f" (cosine runtimeEmb oracle))
  putStrLn (printf "cos(runtime, head_part)=%.6f cos(runtime, dx_part)=%.6f"
    (cosine runtimeEmb headV) (cosine runtimeEmb dxV))
  putStrLn (printf "head_norm=%.6g dx_norm=%.6g cos(head, dx)=%.6f"
    (norm2 headV) (norm2 dxV) (cosine headV dxV))
  let untouched = U.ifilter (\i _ -> oracle U.! i == 0) runtimeEmb
  putStrLn (printf "untouched_coords=%d untouched_runtime_norm=%.6g"
    (U.length untouched) (norm2 untouched))
  gainV <- U.unsafeFreeze gainBar
  let finalRmsRuntime = U.fromListN d
        (map read (take d (drop (paramCount cfg - d) gradLines)))
  when (U.length finalRmsRuntime == d) $ do
    putStrLn (printf "final_rms: cos(runtime, oracle)=%.6f runtime_norm=%.6g oracle_norm=%.6g"
      (cosine finalRmsRuntime gainV) (norm2 finalRmsRuntime) (norm2 gainV))

-- A target is either an explicit completed-step count or "epoch": enough
-- steps that every training window has been consumed at least once.
data TargetSpec = ExplicitSteps Int | EpochSteps

data TrainingMode
  = Standalone TargetSpec
  | Segment Int Int Int Word64 String String

data TrainingProgress = TrainingProgress
  { progressTrainLossEma :: !(Maybe Float)
  , progressPreviousValidationLoss :: !(Maybe Float)
  , progressBestValidationLoss :: !(Maybe Double)
  }

parseTarget :: String -> IO TargetSpec
parseTarget "epoch" = pure EpochSteps
parseTarget value = ExplicitSteps <$> parsePositive "STEPS" value

train :: FilePath -> FilePath -> TrainingMode -> Config -> IO ()
train corpusPath checkpointPath mode cfg =
  withContext (\ctx -> trainInContext ctx corpusPath checkpointPath mode cfg)

-- The body of `train`, taking the device context rather than opening one, so
-- that train-plan can hoist a single context above a whole shard loop.
--
-- Hoisting is a correctness requirement, not just an optimization: CudaBlasOps
-- caches one process-global cuBLAS handle with no destroy path, bound to
-- whichever CUDA context was live when the first GEMM ran.  A loop that opened
-- and closed a context per shard would leave the second shard's first GEMM
-- using a handle bound to a freed context.
trainInContext :: Context -> FilePath -> FilePath -> TrainingMode -> Config -> IO ()
trainInContext ctx corpusPath checkpointPath mode cfg = do
  batchSize <- positiveEnv "TRAIN_BATCH" 1
  microSize <- positiveEnv "MICRO_BATCH" batchSize
  when (microSize > batchSize) (die "MICRO_BATCH must not exceed TRAIN_BATCH")
  checkpointEvery <- positiveEnv "CHECKPOINT_EVERY" 500
  validateEvery <- positiveEnv "VALIDATE_EVERY" 500
  validationWindows <- positiveEnv "VALIDATION_WINDOWS" 256
  clipNorm <- positiveDoubleEnv "GRAD_CLIP" 1
  numerics <- backendNumerics
  corpus <- loadCorpus corpusPath >>= either die pure
  corpusVocab <- maybe (die "corpus has an unsupported tokenizer identity") pure
    (tokenizerVocabularyFromIdentity (corpusTokenizerIdentity corpus))
  when (corpusVocab /= vocabSize cfg) (die
    ("corpus tokenizer vocabulary " ++ show corpusVocab
      ++ " does not match model vocabulary " ++ show (vocabSize cfg)))
  tokenizer <- tokenizerForIdentity (corpusTokenizerIdentity corpus)
  let documentOffset = case mode of
        Standalone _ -> 0
        Segment _ _ _ offset _ _ -> offset
  case mode of
    Standalone _ -> pure ()
    Segment _ _ _ _ _ expected -> when (corpusDatasetIdentity corpus /= expected)
      (die "segment corpus identity does not match the run plan")
  fullSplit <- either die pure (trainingSequencesFrom documentOffset cfg (corpusDocuments corpus))
  -- The validation comparison set is the first VALIDATION_WINDOWS windows;
  -- the same sample feeds the loss, the bits-per-byte scale, and the
  -- bigram gate, so all three observe the same denotation.
  let split = fullSplit { validation = take validationWindows (validation fullSplit) }
  bpbScale <- if null (validation split)
    then pure Nothing
    else Just <$> either die pure (bitsPerByteScale tokenizer (validation split))
  skipBigramGate <- (== Just "1") <$> lookupEnv "SKIP_BIGRAM_GATE"
  gate <- if null (validation split) || skipBigramGate
    then pure Nothing
    else either die (pure . Just) (bigramGateFrom validationWindows documentOffset cfg (corpusDocuments corpus))
  let windowCount = length (training split)
      epochSteps = (windowCount + batchSize - 1) `div` batchSize
  (target, scheduleTotal, segmentStart, sampler, runDatasetIdentity) <- case mode of
    Standalone spec -> case spec of
      ExplicitSteps n -> pure
        (n, n, 0, randomSampler batchSize (training split), corpusDatasetIdentity corpus)
      EpochSteps -> pure
        (epochSteps, epochSteps, 0, epochSampler batchSize (training split), corpusDatasetIdentity corpus)
    Segment total start end _ globalIdentity _ -> do
      when (start < 0 || start >= end || end > total)
        (die "segment requires 0 <= START < END <= GLOBAL_TOTAL_STEPS")
      when (end - start /= epochSteps) (die
        ("segment plan step count differs from corpus: planned " ++ show (end - start)
          ++ ", corpus requires " ++ show epochSteps))
      pure (end, total, start,
        segmentSampler start (epochSampler batchSize (training split)), globalIdentity)
  case mode of
    Standalone (ExplicitSteps _) -> pure ()
    _ -> logTraining ("epoch segment: " ++ show windowCount
      ++ " training windows / batch " ++ show batchSize
      ++ " = " ++ show epochSteps ++ " steps, global "
      ++ show segmentStart ++ ".." ++ show target ++ "/" ++ show scheduleTotal)
  let identity = Identity (modelId cfg) (corpusTokenizerIdentity corpus) runDatasetIdentity
      optCfg = optimizerFor scheduleTotal
  existing <- doesFileExist checkpointPath
  checkpoint <- if existing
    then loadCheckpoint checkpointPath >>= either die
      (validateResume cfg identity optCfg clipNorm numerics)
    else do
      when (segmentStart /= 0) (die "cannot begin a nonzero segment without the global checkpoint")
      fresh <- pure (newCheckpoint cfg identity optCfg clipNorm numerics)
      initFrom <- lookupEnv "TRAIN_INIT"
      case initFrom of
        Nothing -> pure fresh
        Just source -> do
          -- Warm start: copy only the parameters of a compatible previous
          -- run into a NEW run; identity, schedule, optimizer moments,
          -- step, and PRNG are all fresh.
          previous <- loadCheckpoint source >>= either die pure
          let previousManifest = checkpointManifest previous
              previousIdentity = manifestIdentity previousManifest
          when (manifestConfig previousManifest /= cfg)
            (die ("TRAIN_INIT checkpoint has a different model configuration: " ++ source))
          when (modelIdentity previousIdentity /= modelId cfg
            || tokenizerIdentity previousIdentity /= corpusTokenizerIdentity corpus)
            (die ("TRAIN_INIT checkpoint has a different model or tokenizer identity: " ++ source))
          logTraining ("warm start: parameters initialized from " ++ source
            ++ " (completed step " ++ show (adamStep (checkpointOptimizer previous)) ++ ")")
          pure fresh { checkpointParameters = checkpointParameters previous }
  when (adamStep (checkpointOptimizer checkpoint) < segmentStart)
    (die "checkpoint is behind this segment's start step")
  when (adamStep (checkpointOptimizer checkpoint) > target)
    (die "checkpoint has already passed this segment's target step")
  gpuCfg <- gpuConfigIO cfg >>= either die pure
  mask <- either die pure (decayMask cfg)
  let params0 = checkpointParameters checkpoint
      state0 = checkpointOptimizer checkpoint
      n = paramCount cfg
  logTraining ("training config=" ++ show cfg
    ++ " target=" ++ show target
    ++ " schedule_total=" ++ show scheduleTotal
    ++ " completed=" ++ show (adamStep state0)
    ++ " batch=" ++ show batchSize
    ++ " micro=" ++ show microSize
    ++ " numerics=" ++ show numerics
    ++ " grad_clip=" ++ show clipNorm
    ++ " checkpoint_every=" ++ show checkpointEvery
    ++ " validate_every=" ++ show validateEvery
    ++ " validation_windows=" ++ show (length (validation split)))
  case gate of
    Nothing -> pure ()
    Just g -> logTraining ("bigram gate: sample=" ++ show (gateSampleCrossEntropy g)
      ++ " nats full=" ++ show (gateFullCrossEntropy g) ++ " nats")
  do
    params <- uploadF32Vector ctx params0
    m <- uploadF32Vector ctx (firstMoment state0)
    v <- uploadF32Vector ctx (secondMoment state0)
    withBoolVector ctx mask $ \deviceMask -> do
      -- DUMP_CHECKPOINTS=1: keep a step-suffixed copy of every snapshot so
      -- the act-stats diagnostic can walk the trajectory afterwards.
      dumpCheckpoints <- (== Just "1") <$> lookupEnv "DUMP_CHECKPOINTS"
      let saveSnapshot step rng best deviceParams deviceM deviceV = do
            hostParams <- downloadF32Vector ctx n deviceParams
            hostM <- downloadF32Vector ctx n deviceM
            hostV <- downloadF32Vector ctx n deviceV
            let snapshot = checkpoint
                  { checkpointParameters = hostParams
                  , checkpointOptimizer = AdamWState step hostM hostV
                  , checkpointBestValidationLoss = best
                  , checkpointPRNG = rng
                  }
            saved <- saveCheckpointAtomic checkpointPath snapshot
            either die pure saved
            logTraining ("checkpoint step=" ++ show step ++ " path=" ++ checkpointPath)
            when dumpCheckpoints $ do
              let stepPath = checkpointPath ++ ".step-" ++ show step
              copyFile checkpointPath stepPath
              logTraining ("checkpoint copy " ++ stepPath)
      -- DUMP_GRAD_SLICES=N: every N steps print each named slice's clipped
      -- gradient norm and post-update parameter norm — the where-does-the-
      -- gradient-live / which-parameters-drift diagnostic.
      dumpEvery <- maybe (0 :: Int) (\raw -> maybe 0 id (readMaybe raw)) <$> lookupEnv "DUMP_GRAD_SLICES"
      let layoutSlices = either (const []) id (namedLayout cfg)
          dumpSlices step gradientDevice paramsDevice =
            when (dumpEvery > 0 && step `mod` dumpEvery == 0) $ do
              gradientHost <- downloadF32Vector ctx n gradientDevice
              paramsHost <- downloadF32Vector ctx n paramsDevice
              let sliceNorm values slice = sqrt
                    (U.sum (U.map (\x -> x * x)
                      (U.slice (sliceOffset slice) (sliceLength slice) values))) :: Double
              mapM_ (\slice -> hPutStrLn stderr ("slice step=" ++ show step
                ++ " name=" ++ sliceName slice
                ++ printf " grad=%.6g" (sliceNorm gradientHost slice)
                ++ printf " param=%.6g" (sliceNorm paramsHost slice))) layoutSlices
              -- embedding-gradient common-mode fraction |mean_w row|/mean_w|row|:
              -- ≈1 means the head gradient is one shared direction (logit
              -- scale/null drift), ≈0 means genuinely per-token signal.
              case [ s | s <- layoutSlices, sliceName s == "embedding" ] of
                [s] | modelDim cfg > 0 && sliceLength s `mod` modelDim cfg == 0 -> do
                  let d0 = modelDim cfg
                      rows0 = sliceLength s `div` d0
                      values = U.slice (sliceOffset s) (sliceLength s) gradientHost
                      rowsL = [ U.toList (U.slice (r * d0) d0 values) | r <- [0 .. rows0 - 1] ]
                      meanRow = map (/ fromIntegral rows0)
                        (foldl' (zipWith (+)) (replicate d0 0) rowsL)
                      rowNorm r = sqrt (sum (map (\x -> x * x) r))
                      meanNorm = sum (map rowNorm rowsL) / fromIntegral rows0
                  hPutStrLn stderr ("slice step=" ++ show step
                    ++ printf " embedding_common_mode=%.6g"
                        (rowNorm meanRow / max 1e-30 meanNorm))
                _ -> pure ()
              hFlush stderr
      -- FREEZE_TRUNK=1 / TRUNK_GRAD_SCALE=k: scale every non-embedding
      -- gradient coordinate by k (0 = train only the tied embedding),
      -- applied BEFORE clipping so the probe is semantically an
      -- embedding-only (or drift-attenuated) model, not a clip artifact.
      trunkScale <- do
        freeze <- (== Just "1") <$> lookupEnv "FREEZE_TRUNK"
        pure (if freeze then 0 else envFloat "TRUNK_GRAD_SCALE" 1)
      let embeddingLength = case [ s | s <- layoutSlices, sliceName s == "embedding" ] of
            [s] | sliceOffset s == 0 -> sliceLength s
            _ -> 0
      when (trunkScale /= 1 && embeddingLength == 0)
        (die "FREEZE_TRUNK/TRUNK_GRAD_SCALE require the embedding slice at layout offset 0")
      when (trunkScale /= 1) (logTraining ("trunk gradient scale " ++ show trunkScale
        ++ " (first " ++ show embeddingLength ++ " embedding coordinates unscaled)"))
      let maskGradient g
            | trunkScale == 1 = pure g
            | otherwise = do
                hostG <- downloadF32Vector ctx n g
                freeF32 ctx g
                uploadF32Vector ctx (U.imap
                  (\i x -> if i < embeddingLength then x else x * realToFrac trunkScale)
                  hostG)
      -- DUMP_GRAD_VECTOR=path: at step 1 write the RAW model gradient
      -- (pre-mask, pre-clip) and the exact batch tokens, so an offline f64
      -- oracle can recompute the same step's gradient and compare.
      dumpVectorPath <- lookupEnv "DUMP_GRAD_VECTOR"
      let dumpVector step batch g = case dumpVectorPath of
            Just path | step == 1 -> do
              hostG <- downloadF32Vector ctx n g
              writeFile (path ++ ".tokens")
                (unlines (map (unwords . map show) batch))
              writeFile path (unlines (map show (U.toList hostG)))
              logTraining ("dumped step-1 gradient (" ++ show n
                ++ " floats) and batch to " ++ path)
            _ -> pure ()
      let resumedBest = checkpointBestValidationLoss checkpoint
          segmentBest = case mode of
            Segment _ start _ _ _ _ | adamStep state0 == start -> Nothing
            _ -> resumedBest
          progress0 = TrainingProgress Nothing Nothing segmentBest
      (paramsFinal, mFinal, vFinal, rngFinal, progressFinal) <-
        loop ctx gpuCfg n optCfg split sampler target (adamStep state0) microSize checkpointEvery
          validateEvery clipNorm bpbScale
          (gateSampleCrossEntropy <$> gate)
          saveSnapshot dumpSlices dumpVector maskGradient params m v deviceMask (checkpointPRNG checkpoint)
          progress0
      saveSnapshot target rngFinal (progressBestValidationLoss progressFinal) paramsFinal mFinal vFinal
      logTraining ("saved checkpoint at completed step " ++ show target ++ ": " ++ checkpointPath)
      mapM_ (freeF32 ctx) [paramsFinal, mFinal, vFinal]

-- One segment line of a run plan, as deploy/plan-corpus writes it:
--   segment <k> <document_offset> <docs> <corpus_id> <tw> <vw> <steps> <seg_start> <seg_end>
data PlanSegment = PlanSegment
  { planSegmentIndex :: !Int
  , planSegmentOffset :: !Word64
  , planSegmentCorpusIdentity :: !String
  , planSegmentStart :: !Int
  , planSegmentEnd :: !Int
  }

-- Header: plan <version> <global_total_steps> <global_id> <...>
parsePlan :: String -> Either String (Int, String, [PlanSegment])
parsePlan contents = case map words (lines contents) of
  [] -> Left "plan is empty"
  (header : rest) -> do
    (total, globalIdentity) <- case header of
      ("plan" : _version : totalText : globalIdentity : _) ->
        case readMaybe totalText of
          Just total | total > 0 -> Right (total, globalIdentity)
          _ -> Left "plan header has a non-positive global step total"
      _ -> Left "plan header must begin with `plan`"
    segments <- mapM parseSegment [fields | fields <- rest, take 1 fields == ["segment"]]
    when (null segments) (Left "plan contains no segment lines")
    pure (total, globalIdentity, segments)
  where
    parseSegment fields = case fields of
      ["segment", indexText, offsetText, _docs, corpusIdentity,
        _tw, _vw, _steps, startText, endText] ->
        case (readMaybe indexText, readMaybe offsetText,
              readMaybe startText, readMaybe endText) of
          (Just index, Just offset, Just start, Just end) ->
            Right (PlanSegment index offset corpusIdentity start end)
          _ -> Left ("plan segment has unparseable numbers: " ++ unwords fields)
      _ -> Left ("plan segment has the wrong field count: " ++ unwords fields)

-- Trains every remaining shard of a run plan inside ONE process and ONE device
-- context, replacing deploy/train-cloud.sh's loop of train-segment processes.
--
-- Each of those processes paid CUDA context creation (5.15 s measured on a
-- 5090), a Futhark kernel compile or cache load, its own RTS and binary
-- startup, and a checkpoint round trip.  The run document attributes ~24% of
-- the wiki run's wall clock to exactly this; at 304 shards the context
-- creation alone is ~26 minutes of paid GPU time.
--
-- Deliberately calls trainInContext per shard with no state carried across the
-- boundary beyond the checkpoint file itself.  That makes the whole loop
-- exactly N sequential train-segment invocations with the context lifted out,
-- which is what backend/test's equivalence gate can prove byte for byte.
-- Keeping params/m/v device-resident across shards would save the per-shard
-- checkpoint load and the three uploads on top of this; it is a separate
-- change, because it is the point where the trajectory could stop being
-- reproducible by the fallback path.
--
-- Resume comes from the checkpoint's own completed step, not from the .done
-- markers: the markers are shell state that can disagree with the checkpoint
-- if a process died between the save and the touch.  They are still written,
-- because deploy/pull-stages.sh counts them for progress.
trainPlan :: FilePath -> FilePath -> FilePath -> String -> Config -> IO ()
trainPlan planPath runDir checkpointPath size cfg = do
  contents <- readFile planPath
  (globalTotal, globalIdentity, segments) <- either die pure (parsePlan contents)
  maxShards <- maybe (0 :: Int) (\raw -> maybe 0 id (readMaybe raw)) <$> lookupEnv "MAX_SHARDS"
  completed <- do
    existing <- doesFileExist checkpointPath
    if existing
      then adamStep . checkpointOptimizer <$> (loadCheckpoint checkpointPath >>= either die pure)
      else pure 0
  let remaining = [segment | segment <- segments, planSegmentEnd segment > completed]
      selected = if maxShards > 0 then take maxShards remaining else remaining
  logTraining ("train-plan: " ++ show (length segments) ++ " segments, completed step "
    ++ show completed ++ "/" ++ show globalTotal ++ ", " ++ show (length selected)
    ++ " to train this run")
  -- ONE context for every shard below.  See trainInContext's note on why this
  -- is required rather than merely faster.
  withContext $ \ctx ->
    let go [] = pure ()
        go (segment : rest) = do
          let index = planSegmentIndex segment
              corpusPath = runDir ++ "/shard-" ++ show index ++ "-" ++ size ++ ".corpus"
              marker = runDir ++ "/shard-" ++ show index ++ "-" ++ size ++ ".done"
          present <- doesFileExist corpusPath
          if not present
            then logTraining ("train-plan: corpus for shard " ++ show index
              ++ " is not present, stopping cleanly here: " ++ corpusPath)
            else do
              logTraining ("train-plan: shard " ++ show index ++ "  global "
                ++ show (planSegmentStart segment) ++ ".." ++ show (planSegmentEnd segment)
                ++ " / " ++ show globalTotal)
              trainInContext ctx corpusPath checkpointPath
                (Segment globalTotal (planSegmentStart segment) (planSegmentEnd segment)
                  (planSegmentOffset segment) globalIdentity
                  (planSegmentCorpusIdentity segment)) cfg
              writeFile marker ""
              -- The shard's ~3.2 GB of boxed [[Int64]] windows and its corpus
              -- die with the call above; this is what makes the RTS hand the
              -- pages back before the next shard allocates its own.
              performGC
              go rest
    in go selected
  logTraining ("train-plan: finished. checkpoint: " ++ checkpointPath)

-- Synchronized step-time benchmark per the measurement contract: every
-- measured interval starts with both device queues drained (the previous
-- step ends in synchronize) and ends after its own synchronize, so no
-- interval includes pending work from before its start or omits work queued
-- before its end. Reports median/p95/mean over BENCH_STEPS post-warmup
-- steps, tokens/s, and GEMM-only FLOP throughput (MFU against
-- BENCH_PEAK_TFLOPS when given; the fused backend reports no GEMM FLOPs).
bench :: FilePath -> Config -> IO ()
bench corpusPath cfg = do
  batchSize <- positiveEnv "TRAIN_BATCH" 1
  microSize <- positiveEnv "MICRO_BATCH" batchSize
  when (microSize > batchSize) (die "MICRO_BATCH must not exceed TRAIN_BATCH")
  warmupSteps <- positiveEnv "BENCH_WARMUP" 10
  benchSteps <- positiveEnv "BENCH_STEPS" 100
  clipNorm <- positiveDoubleEnv "GRAD_CLIP" 1
  numerics <- backendNumerics
  peakTflops <- ((>>= readMaybe) <$> lookupEnv "BENCH_PEAK_TFLOPS") :: IO (Maybe Double)
  corpus <- loadCorpus corpusPath >>= either die pure
  corpusVocab <- maybe (die "corpus has an unsupported tokenizer identity") pure
    (tokenizerVocabularyFromIdentity (corpusTokenizerIdentity corpus))
  when (corpusVocab /= vocabSize cfg) (die
    ("corpus tokenizer vocabulary " ++ show corpusVocab
      ++ " does not match model vocabulary " ++ show (vocabSize cfg)))
  split <- either die pure (trainingSequencesFrom 0 cfg (corpusDocuments corpus))
  when (null (training split)) (die "corpus yields no training windows")
  let total = warmupSteps + benchSteps
      sampler = randomSampler batchSize (training split)
      optCfg = optimizerFor total
      identity = Identity (modelId cfg) (corpusTokenizerIdentity corpus)
        (corpusDatasetIdentity corpus)
      fresh = newCheckpoint cfg identity optCfg clipNorm numerics
      state0 = checkpointOptimizer fresh
      n = paramCount cfg
  mask <- either die pure (decayMask cfg)
  gpuCfg <- gpuConfigIO cfg >>= either die pure
  logTraining ("bench config=" ++ show cfg
    ++ " batch=" ++ show batchSize
    ++ " micro=" ++ show microSize
    ++ " numerics=" ++ show numerics
    ++ " grad_clip=" ++ show clipNorm
    ++ " warmup=" ++ show warmupSteps
    ++ " steps=" ++ show benchSteps)
  withContext $ \ctx -> do
    params <- uploadF32Vector ctx (checkpointParameters fresh)
    m <- uploadF32Vector ctx (firstMoment state0)
    v <- uploadF32Vector ctx (secondMoment state0)
    withBoolVector ctx mask $ \deviceMask -> do
      let o field = realToFrac (field optCfg)
          benchStep step (rng, ps, ms, vs) = do
            let (batch, rng') = sampler step rng
                lr = realToFrac (learningRate optCfg step)
            when (null batch) (die "internal error: sampled an empty training batch")
            (loss, gradient) <- microLossGrad ctx gpuCfg n microSize batch ps
            (gradientNorm, clipped) <- bracket (pure gradient) (freeF32 ctx) $ \g ->
              clipGlobalNorm ctx clipNorm g
            (ps', ms', vs') <- bracket (pure clipped) (freeF32 ctx) $ \g ->
              adamwStep ctx (fromIntegral step) lr (o beta1) (o beta2)
                (o adamEpsilon) (o weightDecay) ps g ms vs deviceMask
            mapM_ (freeF32 ctx) [ps, ms, vs]
            synchronize ctx
            loss `seq` gradientNorm `seq` pure (rng', ps', ms', vs')
          measure step state durations
            | step > total = pure (state, durations)
            | otherwise = do
                when (step == warmupSteps + 1) (resetGemmFlopCount ctx)
                startNs <- getMonotonicTimeNSec
                state' <- benchStep step state
                endNs <- getMonotonicTimeNSec
                measure (step + 1) state'
                  (if step > warmupSteps
                    then (endNs - startNs) : durations
                    else durations)
      ((_, psF, msF, vsF), durationsRev) <-
        measure 1 (checkpointPRNG fresh, params, m, v) []
      flops <- gemmFlopsSinceReset ctx
      mapM_ (freeF32 ctx) [psF, msF, vsF]
      let seconds = map ((/ 1e9) . fromIntegral) (reverse durationsRev) :: [Double]
          sorted = sortOn id seconds
          percentile p = sorted !!
            min (length sorted - 1)
              (max 0 (ceiling (p / 100 * fromIntegral (length sorted) :: Double) - 1))
          totalSeconds = sum seconds
          targetsPerStep = batchSize * (contextSize cfg - 1)
          tokensPerSecond =
            fromIntegral (benchSteps * targetsPerStep) / totalSeconds :: Double
          flopsPerStep = fromIntegral flops / fromIntegral benchSteps :: Double
          gemmTflops = fromIntegral flops / totalSeconds / 1e12 :: Double
      printf "bench steps=%d median=%.6fs p95=%.6fs mean=%.6fs\n"
        benchSteps (percentile 50) (percentile 95) (totalSeconds / fromIntegral benchSteps)
      printf "bench target_tokens_per_second=%.1f\n" tokensPerSecond
      if flops == 0
        then putStrLn "bench gemm_flops: none counted (fused backend; MFU n/a)"
        else case peakTflops of
          Just peak -> printf "bench gemm_flops_per_step=%.4g gemm_tflops=%.4f mfu=%.4f%%\n"
            flopsPerStep gemmTflops (100 * gemmTflops / peak)
          Nothing -> printf "bench gemm_flops_per_step=%.4g gemm_tflops=%.4f (set BENCH_PEAK_TFLOPS for MFU)\n"
            flopsPerStep gemmTflops

-- Given the one-based step and the PRNG, a sampler yields that step's
-- batch.  The random sampler threads the PRNG; the epoch sampler is a
-- pure function of the step, so resume needs only the completed count.
type Sampler = Int -> PRNGState -> ([[Int64]], PRNGState)

randomSampler :: Int -> [[Int64]] -> Sampler
randomSampler batchSize windows _ rng = sampleBatch batchSize rng windows

-- Deterministic full-coverage order: windows sorted by a hash of their
-- index, sliced cyclically by step.  After ceil(count/batch) steps every
-- training window has been consumed at least once; the final slice wraps.
epochSampler :: Int -> [[Int64]] -> Sampler
epochSampler batchSize windows = \step rng ->
  let start = (step - 1) * batchSize `mod` count
      batch = [permuted V.! ((start + i) `mod` count) | i <- [0 .. batchSize - 1]]
  in (batch, rng)
  where
    count = V.length permuted
    permuted = V.fromList (map snd (sortOn fst (zipWith tag [0 ..] windows)))
    tag index window = (hashIndex index, window)
    hashIndex :: Word64 -> Word64
    hashIndex x0 = x3 `xor` (x3 `shiftR` 31)
      where
        x1 = (x0 + 0x45504f4348) `xor` ((x0 + 0x45504f4348) `shiftR` 30)
        x2 = x1 * 0xbf58476d1ce4e5b9
        x3 = (x2 `xor` (x2 `shiftR` 27)) * 0x94d049bb133111eb

segmentSampler :: Int -> Sampler -> Sampler
segmentSampler segmentStart sampler globalStep = sampler (globalStep - segmentStart)

loop
  :: Context
  -> GpuConfig
  -> Int
  -> AdamWConfig
  -> Split [Int64]
  -> Sampler
  -> Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> Float
  -> Maybe Double
  -> Maybe Double
  -> (Int -> PRNGState -> Maybe Double -> F32Array -> F32Array -> F32Array -> IO ())
  -> (Int -> F32Array -> F32Array -> IO ())
  -> (Int -> [[Int64]] -> F32Array -> IO ())
  -> (F32Array -> IO F32Array)
  -> F32Array
  -> F32Array
  -> F32Array
  -> BoolArray
  -> PRNGState
  -> TrainingProgress
  -> IO (F32Array, F32Array, F32Array, PRNGState, TrainingProgress)
loop ctx gpuCfg n optCfg split sampler target completed microSize checkpointEvery validateEvery clipNorm bpbScale gate saveSnapshot dumpSlices dumpVector maskGradient params m v mask rng progress
  | completed >= target = pure (params, m, v, rng, progress)
  | otherwise = do
      let step = completed + 1
          (batch, rng') = sampler step rng
          lr = realToFrac (learningRate optCfg step)
      when (null batch) (die "internal error: sampled an empty training batch")
      (loss, gradient) <- microLossGrad ctx gpuCfg n microSize batch params
      dumpVector step batch gradient
      (gradientNorm, clipped) <- bracket (maskGradient gradient) (freeF32 ctx) $ \g ->
        clipGlobalNorm ctx clipNorm g
      (params', m', v') <- bracket (pure clipped) (freeF32 ctx) $ \g -> do
        result@(nextParams, _, _) <- adamwStep ctx (fromIntegral step) lr (f beta1) (f beta2) (f adamEpsilon) (f weightDecay) params g m v mask
        dumpSlices step g nextParams
        pure result
      freeF32 ctx params
      freeF32 ctx m
      freeF32 ctx v
      let ema = case progressTrainLossEma progress of
            Nothing -> loss
            Just previous -> trainLossEmaDecay * previous + (1 - trainLossEmaDecay) * loss
          progressWithLoss = progress { progressTrainLossEma = Just ema }
      (progress', validationText) <- if null (validation split) || (step `mod` validateEvery /= 0 && step /= target)
        then pure (progressWithLoss, "")
        else do
          let val = validation split
          when (null val) (die "internal error: selected an empty validation batch")
          valLoss <- chunkedMeanLoss ctx gpuCfg microSize val params'
          let gateText = case gate of
                Nothing -> ""
                Just g -> " gate=" ++ show g
                  ++ (if realToFrac valLoss < g then " beats-gate" else " behind-gate")
              bpbText = maybe "" (\scale -> " bits_per_byte="
                ++ formatDouble (realToFrac valLoss * scale)) bpbScale
              valDouble = realToFrac valLoss
              previousBest = progressBestValidationLoss progressWithLoss
              best' = maybe valDouble (min valDouble) previousBest
              deltaText = maybe "na" (formatSignedFloat . (valLoss -))
                (progressPreviousValidationLoss progressWithLoss)
              newBest = maybe True (valDouble <) previousBest
              validation = " validation_loss=" ++ formatFloat valLoss
                ++ " validation_delta=" ++ deltaText
                ++ " best_validation_loss=" ++ formatFloat (realToFrac best')
                ++ " new_best=" ++ boolText newBest
                ++ bpbText ++ gateText
          pure (progressWithLoss
            { progressPreviousValidationLoss = Just valLoss
            , progressBestValidationLoss = Just best'
            }, validation)
      logTraining ("step=" ++ show step ++ "/" ++ show (totalSteps optCfg)
        ++ " progress=" ++ printf "%.3f%%" (100 * fromIntegral step / fromIntegral (totalSteps optCfg) :: Double)
        ++ " lr=" ++ formatFloat lr
        ++ " train_loss=" ++ formatFloat loss
        ++ " train_loss_ema=" ++ formatFloat ema
        ++ " gradient_norm=" ++ formatFloat gradientNorm
        ++ " clipped=" ++ boolText (gradientNorm > clipNorm)
        ++ validationText)
      when (step `mod` checkpointEvery == 0 && step /= target) $
        saveSnapshot step rng' (progressBestValidationLoss progress') params' m' v'
      loop ctx gpuCfg n optCfg split sampler target step microSize checkpointEvery validateEvery clipNorm bpbScale gate saveSnapshot dumpSlices dumpVector maskGradient
        params' m' v' mask rng' progress'
  where f field = realToFrac (field optCfg)

logTraining :: String -> IO ()
logTraining message = do
  timestamp <- formatTime defaultTimeLocale "%Y-%m-%d %H:%M %Z" <$> getZonedTime
  putStrLn ("[" ++ timestamp ++ "] " ++ message)

formatFloat :: Float -> String
formatFloat = printf "%.7g"

formatDouble :: Double -> String
formatDouble = printf "%.7g"

formatSignedFloat :: Float -> String
formatSignedFloat = printf "%+.7g"

trainLossEmaDecay :: Float
trainLossEmaDecay = 0.98

boolText :: Bool -> String
boolText True = "true"
boolText False = "false"

-- Micro-batched gradient of the effective-batch mean loss.  Each chunk's
-- adjoints are seeded with 1/effective-batch inside the kernel, so the
-- accumulated gradient equals the full-batch gradient up to f32 summation
-- order, and one AdamW step per effective batch keeps step semantics.
microLossGrad :: Context -> GpuConfig -> Int -> Int -> [[Int64]] -> F32Array -> IO (Float, F32Array)
microLossGrad ctx gpuCfg n microSize batch params = do
  acc0 <- zeroVector ctx n
  foldM accumulate (0, acc0) (chunksOf microSize batch)
  where
    effective = fromIntegral (length batch)
    accumulate (lossSoFar, acc) chunk = do
      width <- case chunk of
        [] -> die "internal error: empty micro-batch chunk"
        first : _ -> pure (length first)
      (partial, acc') <- withI64_2d ctx (length chunk) width (concat chunk)
        (microBatchLossGrad ctx gpuCfg effective acc params)
      freeF32 ctx acc
      pure (lossSoFar + partial, acc')

-- Count-weighted mean over equal chunks; identical to one batchMeanLoss
-- call up to f32 association, but each kernel launch stays watchdog-sized.
chunkedMeanLoss :: Context -> GpuConfig -> Int -> [[Int64]] -> F32Array -> IO Float
chunkedMeanLoss ctx gpuCfg microSize windows params = do
  weighted <- mapM chunkLoss (chunksOf microSize windows)
  pure (sum weighted / fromIntegral (length windows))
  where
    chunkLoss chunk = do
      width <- case chunk of
        [] -> die "internal error: empty validation chunk"
        first : _ -> pure (length first)
      chunkMean <- withI64_2d ctx (length chunk) width (concat chunk)
        (batchMeanLoss ctx gpuCfg params)
      pure (fromIntegral (length chunk) * chunkMean)

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf size values = take size values : chunksOf size (drop size values)

bitsPerByteScale :: Tokenizer -> [[Int64]] -> Either String Double
bitsPerByteScale tokenizer windows = do
  let targets = concatMap (drop 1) windows
      ordinary = [fromIntegral token | token <- targets, token >= 2]
      predictionCount = length targets
  byteChunks <- mapM (decodeWith tokenizer . pure) ordinary
  let byteCount = sum (map BS.length byteChunks)
  when (predictionCount == 0 || byteCount == 0)
    (Left "validation sample has no ordinary target bytes")
  pure (fromIntegral predictionCount / (fromIntegral byteCount * log 2))

trainingSequencesFrom :: Word64 -> Config -> [Document] -> Either String (Split [Int64])
trainingSequencesFrom offset cfg documents = do
  mapM_ validateDocument documents
  split <- trainerWindowSplitFrom offset (contextSize cfg) documents
  pure (Split (convert (training split)) (convert (validation split)))
  where
    -- A pure map forced in parallel chunks: the value is unchanged, only
    -- where and when it is evaluated.
    convert windows = map (map fromIntegral) windows `using` parListChunk 4096 rdeepseq
    validateDocument document = when
      (any (\token -> token < 2 || token >= vocabSize cfg) (documentTokens document))
      (Left ("document " ++ documentId document ++ " contains a token outside model vocabulary"))

newCheckpoint :: Config -> Identity -> AdamWConfig -> Float -> Numerics -> Checkpoint
newCheckpoint cfg identity optCfg clipNorm numerics =
  Checkpoint manifest params (initAdamW count) Nothing initialPRNG
  where
    count = paramCount cfg
    manifest = Manifest artifactVersion cfg count canonicalLayoutIdentity canonicalLayoutVersion
      optCfg identity (realToFrac clipNorm) numerics
    params = either error (U.concat . map initialize) (namedLayout cfg)
    initialize slice
      | initZeroOutput && (".wo" `isSuffixOf` sliceName slice
          || ".wdown" `isSuffixOf` sliceName slice) =
          U.replicate (sliceLength slice) 0
      | sliceDecay slice =
          U.generate (sliceLength slice) (\i -> initNoise (sliceOffset slice + i + 1))
      | otherwise = U.replicate (sliceLength slice) 1

-- Init experiment overrides (probes only; the initialization is part of a
-- run's identity, so record any override with a published run).
-- INIT_SCALE: amplitude, default the historical 0.02 — which is fan-in
-- independent, the prime suspect for the bpe10m gradient-norm collapse.
-- INIT_KIND=hash: independent splitmix64 noise instead of the historical
-- deterministic sin sweep (which has strong serial structure).
{-# NOINLINE initScale #-}
initScale :: Double
initScale = envFloat "INIT_SCALE" 0.02

{-# NOINLINE initKind #-}
initKind :: String
initKind = unsafePerformIO (maybe "sin" id <$> lookupEnv "INIT_KIND")

-- INIT_ZERO_OUT=1: zero-initialize every block's output projections (wo,
-- wdown) so blocks start as the identity and the residual stream stays
-- token-dominated — the standard cure for residual-stream explosion, which
-- the per-slice gradient dump identified at bpe10m (trunk gradients die
-- behind the final rms_norm's 1/rms attenuation while the head keeps
-- learning).
{-# NOINLINE initZeroOutput #-}
initZeroOutput :: Bool
initZeroOutput = unsafePerformIO ((== Just "1") <$> lookupEnv "INIT_ZERO_OUT")

initNoise :: Int -> Double
initNoise index = case initKind of
  "hash" -> initScale * hashNoise index
  _ -> initScale * sin (fromIntegral index * 12.9898)

-- splitmix64 finalizer mapped to [-1, 1).
hashNoise :: Int -> Double
hashNoise index =
  let z0 = fromIntegral index * 0x9e3779b97f4a7c15 :: Word64
      z1 = (z0 `xor` (z0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
      z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb
      z3 = z2 `xor` (z2 `shiftR` 31)
  in fromIntegral z3 / 9223372036854775808 - 1

validateResume :: Config -> Identity -> AdamWConfig -> Float -> Numerics -> Checkpoint -> IO Checkpoint
validateResume cfg identity optCfg clipNorm numerics checkpoint = do
  let manifest = checkpointManifest checkpoint
  when (manifestConfig manifest /= cfg) (die "checkpoint config does not match requested model size")
  when (manifestIdentity manifest /= identity) (die "checkpoint model/tokenizer/dataset identity mismatch")
  when (manifestOptimizerConfig manifest /= optCfg) (die
    ("checkpoint optimizer config does not exactly match this run\n"
      ++ "  checkpoint: " ++ show (manifestOptimizerConfig manifest) ++ "\n"
      ++ "  this run:   " ++ show optCfg ++ "\n"
      ++ "  the schedule is anchored at run creation; to train with a"
      ++ " different target (or a different TRAIN_BATCH for an epoch"
      ++ " target), start a new CHECKPOINT path"))
  when (manifestClipNorm manifest /= realToFrac clipNorm) (die
    ("checkpoint gradient clip does not match this run\n"
      ++ "  checkpoint: " ++ show (manifestClipNorm manifest) ++ "\n"
      ++ "  this run:   " ++ show clipNorm ++ " (GRAD_CLIP)\n"
      ++ "  the clip is part of the training trajectory; resume with the"
      ++ " same GRAD_CLIP or start a new CHECKPOINT path"))
  when (manifestNumerics manifest /= numerics) (die
    ("checkpoint numerics do not match this backend\n"
      ++ "  checkpoint: " ++ show (manifestNumerics manifest) ++ "\n"
      ++ "  this run:   " ++ show numerics ++ "\n"
      ++ "  numerics are part of the training trajectory; use the matching"
      ++ " backend or start a new CHECKPOINT path"))
  when (manifestLayoutIdentity manifest /= canonicalLayoutIdentity || manifestLayoutVersion manifest /= canonicalLayoutVersion) (die "checkpoint layout identity mismatch")
  pure checkpoint

-- Silent compatibility probe for checkpoint discovery: exit 0 iff this
-- host's architecture (model identity + canonical layout) can interpret
-- the checkpoint.  Loads and validates the artifact only; no Futhark
-- context is created.  wiki-generate uses this to skip checkpoints written
-- by a different architecture instead of dying on the newest file.
checkCheckpoint :: FilePath -> IO ()
checkCheckpoint path = do
  checkpoint <- loadCheckpoint path >>= either die pure
  let manifest = checkpointManifest checkpoint
      cfg = manifestConfig manifest
      identity = manifestIdentity manifest
  when (modelIdentity identity /= modelId cfg)
    (die "checkpoint model identity is not supported by this host")
  when (manifestLayoutIdentity manifest /= canonicalLayoutIdentity
        || manifestLayoutVersion manifest /= canonicalLayoutVersion)
    (die "checkpoint layout identity is not supported by this host")
  putStrLn ("compatible: " ++ path)

-- Offline evaluation on a fixed corpus: the measurement the training loop's
-- periodic validation only samples, run once over every window instead.
--
-- The corpus is consumed as-is -- deliberately NOT through
-- trainingSequencesFrom, which would re-split an already-held-out set and
-- silently score 90% of it.  The caller supplies a corpus that is held out by
-- construction (see `formal-transformer build-eval`).
--
-- Reported with a standard error, because a bits-per-byte figure without one
-- invites exactly the mistake the 2026-07-25 run's last log line encourages:
-- reading a small sample's draw as the model's quality.  Chunk means are
-- independent samples of equal size, so sd(chunk means)/sqrt(chunks) is the
-- standard error of the overall mean.
evaluate :: FilePath -> FilePath -> IO ()
evaluate checkpointPath corpusPath = do
  microSize <- positiveEnv "MICRO_BATCH" 8
  checkpoint <- loadCheckpoint checkpointPath >>= either die pure
  let manifest = checkpointManifest checkpoint
      cfg = manifestConfig manifest
      identity = manifestIdentity manifest
  when (modelIdentity identity /= modelId cfg)
    (die "checkpoint model identity is not supported by this host")
  corpus <- loadCorpus corpusPath >>= either die pure
  when (corpusTokenizerIdentity corpus /= tokenizerIdentity identity)
    (die ("corpus tokenizer identity does not match the checkpoint\n  corpus:     "
      ++ corpusTokenizerIdentity corpus
      ++ "\n  checkpoint: " ++ tokenizerIdentity identity))
  tokenizer <- tokenizerForIdentity (tokenizerIdentity identity)
  when (tokenizerVocabSize tokenizer /= vocabSize cfg)
    (die "checkpoint tokenizer vocabulary does not match its model configuration")
  let windows = map (map fromIntegral)
        (concatMap (fullWindows (contextSize cfg)) (corpusDocuments corpus)) :: [[Int64]]
  when (null windows) (die "evaluation corpus yields no full context windows")
  scale <- either die pure (bitsPerByteScale tokenizer windows)
  gpuCfg <- gpuConfigIO cfg >>= either die pure
  let chunks = chunksOf microSize windows
      completed = adamStep (checkpointOptimizer checkpoint)
      scheduled = totalSteps (manifestOptimizerConfig manifest)
  hPutStrLn stderr ("evaluate: " ++ show (length windows) ++ " windows, "
    ++ show (length chunks) ++ " chunks of at most " ++ show microSize)
  results <- withContext $ \ctx ->
    withF32Vector ctx (checkpointParameters checkpoint) $ \params ->
      mapM (chunkMean ctx gpuCfg params) chunks
  let totalWindows = sum (map fst results)
      predictions = sum (map (\w -> length w - 1) windows)
      meanLoss = sum [fromIntegral n * m | (n, m) <- results]
        / fromIntegral totalWindows :: Double
      full = [m | (n, m) <- results, n == microSize]
      standardError
        | length full < 2 = Nothing
        | otherwise =
            let k = length full
                centre = sum full / fromIntegral k
                variance = sum [(m - centre) * (m - centre) | m <- full]
                  / fromIntegral (k - 1)
            in Just (sqrt (variance / fromIntegral k))
      showError formatter = maybe "n/a" formatter standardError
  printf "=== evaluation: %s on %s ===\n" checkpointPath corpusPath
  printf "checkpoint step: %d/%d (%.3f%% of the scheduled run)\n"
    completed scheduled
    (100 * fromIntegral completed / fromIntegral scheduled :: Double)
  printf "config: %s\n" (show cfg)
  printf "dataset fingerprint: %s\n" (corpusDatasetIdentity corpus)
  printf "documents: %d  windows: %d  predictions: %d\n"
    (length (corpusDocuments corpus)) totalWindows predictions
  printf "loss: %.6f nats/token (standard error %s)\n"
    meanLoss (showError (printf "%.6f" :: Double -> String))
  printf "bits_per_byte: %.6f (standard error %s)\n"
    (meanLoss * scale) (showError ((printf "%.6f" :: Double -> String) . (* scale)))
  printf "perplexity: %.4f\n" (exp meanLoss)

-- One evaluation chunk: window count and mean loss over that chunk.
chunkMean :: Context -> GpuConfig -> F32Array -> [[Int64]] -> IO (Int, Double)
chunkMean ctx gpuCfg params chunk = do
  width <- case chunk of
    [] -> die "internal error: empty evaluation chunk"
    first : _ -> pure (length first)
  value <- withI64_2d ctx (length chunk) width (concat chunk)
    (batchMeanLoss ctx gpuCfg params)
  pure (length chunk, realToFrac value)

generate :: FilePath -> String -> Int -> IO ()
generate checkpointPath text budget = do
  checkpoint <- loadCheckpoint checkpointPath >>= either die pure
  let manifest = checkpointManifest checkpoint
      cfg = manifestConfig manifest
      identity = manifestIdentity manifest
  when (modelIdentity identity /= modelId cfg) (die "checkpoint model identity is not supported by this GPU host")
  tokenizer <- tokenizerForIdentity (tokenizerIdentity identity)
  when (tokenizerVocabSize tokenizer /= vocabSize cfg)
    (die "checkpoint tokenizer vocabulary does not match its model configuration")
  gpuCfg <- gpuConfigIO cfg >>= either die pure
  temperature <- nonnegativeDoubleEnv "TEMPERATURE" 0.8
  topK <- positiveEnv "TOP_K" 40
  seedText <- lookupEnv "SAMPLE_SEED"
  rng <- case seedText of
    Nothing -> pure (checkpointPRNG checkpoint)
    Just value -> seededPRNG <$> parseWord64 "SAMPLE_SEED" value
  hPutStrLn stderr ("generate: temperature=" ++ show temperature
    ++ " top_k=" ++ show topK
    ++ " seed=" ++ maybe "checkpoint-prng" id seedText)
  let promptBytes = Text.encodeUtf8 (Text.pack text)
      prompt = bosToken : encodeWith tokenizer promptBytes
      n = paramCount cfg
      completed = adamStep (checkpointOptimizer checkpoint)
      scheduled = totalSteps (manifestOptimizerConfig manifest)
      progress = 100 * fromIntegral completed / fromIntegral scheduled :: Double
      emit token = do
        bytes <- either die pure (decodeWith tokenizer [token])
        BS.putStr bytes
        hFlush stdout
  printf "=== Wikipedia corpus training: %.3f%% complete (%d/%d updates) ===\n"
    progress completed scheduled
  BS.putStr promptBytes
  hFlush stdout
  _ <- withContext $ \ctx -> withF32Vector ctx (checkpointParameters checkpoint) $ \params ->
    generateLoop ctx gpuCfg cfg params (pickToken temperature topK) emit budget rng prompt []
  putStrLn ""

tokenizerForIdentity :: String -> IO Tokenizer
tokenizerForIdentity identity
  | identity == byteTokenizerIdentity = pure ByteTokenizer
  | otherwise = do
      path <- lookupEnv "TOKENIZER_FILE" >>= maybe
        (die "checkpoint uses BPE; set TOKENIZER_FILE to its .bpe artifact") pure
      bpe <- loadFastBpe path >>= either die pure
      let tokenizer = FastBpeTokenizer bpe
      when (tokenizerIdentityOf tokenizer /= identity)
        (die "TOKENIZER_FILE identity does not match the checkpoint")
      pure tokenizer

-- Incremental decoding: the proved cache-run law executed.  Each prompt or
-- sampled token is fed through decode_step exactly once; GLA layers carry a
-- fixed dk x dv state per head that is never reset (the StateAlgebra run),
-- and the NoPE softmax layers attend over a ring buffer of the trailing
-- context window.  Within the first window this observes the same language
-- as full recomputation (recurrent≡parallel plus causality); per-token cost
-- is O(model) instead of O(window * model).
generateLoop
  :: Context -> GpuConfig -> Config -> F32Array
  -> ([Float] -> PRNGState -> (Int, PRNGState))
  -> (Int -> IO ()) -> Int -> PRNGState -> [Int] -> [Int] -> IO [Int]
generateLoop ctx gpuCfg cfg params pick emit budget rng prompt _ = do
  let d = modelDim cfg
      hd = headDim cfg
      glaStateLength = glaLayerCount cfg * d * hd
      cacheLength = (layerCount cfg `div` 4) * contextSize cfg * d
      step (gla, kc, vc) position token = do
        (logitsArr, gla', kc', vc') <- decodeStep ctx gpuCfg
          (fromIntegral (contextSize cfg)) (fromIntegral position)
          (fromIntegral token) params gla kc vc
        values <- downloadF32 ctx (vocabSize cfg) logitsArr
        freeF32 ctx logitsArr
        pure (values, (gla', kc', vc'))
  gla0 <- zeroVector ctx glaStateLength
  k0 <- zeroVector ctx cacheLength
  v0 <- zeroVector ctx cacheLength
  (promptLogits, primed) <- foldM
    (\(_, states) (position, token) -> step states position token)
    ([], (gla0, k0, v0))
    (zip [0 ..] prompt)
  let go remaining rng' position states logits output
        | remaining <= (0 :: Int) = pure output
        | otherwise = do
            let (token, rng'') = pick logits rng'
            if token == eosToken then pure output
            else do
              unless (token == bosToken) (emit token)
              (logits', states') <- step states position token
              go (remaining - 1) rng'' (position + 1) states' logits'
                 (if token == bosToken then output else output ++ [token])
  go budget rng (length prompt) primed promptLogits []

-- Observation of the model's next-token distribution.  TEMPERATURE=0 is
-- the degenerate greedy observation (the exact argmax path); otherwise the
-- top-K logits are softmaxed at the given temperature and sampled by
-- inverse CDF.  The denotation being observed is unchanged either way.
pickToken :: Float -> Int -> [Float] -> PRNGState -> (Int, PRNGState)
pickToken temperature topK logits rng
  | temperature <= 0 = (argmax logits, rng)
  | otherwise = (select (unitInterval word * total) weights, rng')
  where
    top = take topK (sortOn (negate . snd) (zip [0 ..] logits))
    peak = maximum (map snd top)
    weights =
      [ (index, exp (realToFrac ((logit - peak) / temperature) :: Double))
      | (index, logit) <- top ]
    total = sum (map snd weights)
    (word, rng') = nextWord rng
    select _ [] = argmax logits
    select remaining ((index, weight) : rest)
      | remaining < weight || null rest = index
      | otherwise = select (remaining - weight) rest

-- The high 53 bits of a PRNG word as a Double in [0, 1).
unitInterval :: Word64 -> Double
unitInterval word = fromIntegral (word `shiftR` 11) / 9007199254740992

-- SplitMix64 expansion of one seed word into a full xoshiro256** state:
-- the generator authors' recommended seeding procedure.
seededPRNG :: Word64 -> PRNGState
seededPRNG seed = PRNGState a b c d
  where
    (a, s1) = splitmix seed
    (b, s2) = splitmix s1
    (c, s3) = splitmix s2
    (d, _) = splitmix s3
    splitmix s = (z2 `xor` (z2 `shiftR` 31), s')
      where
        s' = s + 0x9e3779b97f4a7c15
        z1 = (s' `xor` (s' `shiftR` 30)) * 0xbf58476d1ce4e5b9
        z2 = (z1 `xor` (z1 `shiftR` 27)) * 0x94d049bb133111eb

sampleBatch :: Int -> PRNGState -> [a] -> ([a], PRNGState)
sampleBatch count state values = foldl' pick ([], state) [1 .. count]
  where
    pick (chosen, rng) _ = let (word, rng') = nextWord rng
      in (chosen ++ [values !! fromIntegral (word `mod` fromIntegral (length values))], rng')

initialPRNG :: PRNGState
initialPRNG = PRNGState 0x243f6a8885a308d3 0x13198a2e03707344 0xa4093822299f31d0 0x082efa98ec4e6c89

nextWord :: PRNGState -> (Word64, PRNGState)
nextWord (PRNGState s0 s1 s2 s3) = (rotateL (s1 * 5) 7 * 9, PRNGState a b c d)
  where
    t = s1 `shiftL` 17
    a = s0 `xor` s3 `xor` (s1 `xor` s2)
    b = s1 `xor` s2
    c = s2 `xor` s0 `xor` t
    d = rotateL (s3 `xor` s1) 45

argmax :: [Float] -> Int
argmax [] = error "empty logits"
argmax (first : remaining) = fst (foldl' choose (0, first) (zip [1 ..] remaining))
  where choose best@(_, x) candidate@(_, y) = if y > x then candidate else best

takeEnd :: Int -> [a] -> [a]
takeEnd n values = drop (max 0 (length values - n)) values

parsePositive :: String -> String -> IO Int
parsePositive label value = case readMaybe value of
  Just n | n > 0 -> pure n
  _ -> die (label ++ " must be a positive integer")

parseNonnegative :: String -> String -> IO Int
parseNonnegative label value = case readMaybe value of
  Just n | n >= 0 -> pure n
  _ -> die (label ++ " must be a nonnegative integer")

parseWord64 :: String -> String -> IO Word64
parseWord64 label value = case readMaybe value of
  Just number -> pure number
  Nothing -> die (label ++ " must be a nonnegative 64-bit integer")

positiveEnv :: String -> Int -> IO Int
positiveEnv name fallback = do
  value <- lookupEnv name
  case value of
    Nothing -> pure fallback
    Just text -> case readMaybe text of
      Just n | n > 0 -> pure n
      _ -> die (name ++ " must be a positive integer")

positiveDoubleEnv :: String -> Double -> IO Float
positiveDoubleEnv name fallback = do
  value <- lookupEnv name
  case value of
    Nothing -> pure (realToFrac fallback)
    Just text -> case readMaybe text of
      Just number | number > 0 -> pure number
      _ -> die (name ++ " must be a positive number")

nonnegativeDoubleEnv :: String -> Double -> IO Float
nonnegativeDoubleEnv name fallback = do
  value <- lookupEnv name
  case value of
    Nothing -> pure (realToFrac fallback)
    Just text -> case readMaybe text of
      Just number | number >= 0 -> pure number
      _ -> die (name ++ " must be a nonnegative number")
