module FormalTransformer.Model
  ( fullSequenceLogits
  , nextTokenCE
  , fullSequenceLogitsGeneric
  , nextTokenCEGeneric
  , logSumExp
  , softmax
  , ActStats (..)
  , BlockStats (..)
  , fullSequenceStats
  , gateAlpha
  ) where

import Control.Monad (foldM)
import Data.List (transpose)
import FormalTransformer.Config
import FormalTransformer.Layout

fullSequenceLogits :: Config -> [Double] -> [Int] -> Either String [[Double]]
fullSequenceLogits = fullSequenceLogitsGeneric

nextTokenCE :: Config -> [Double] -> [Int] -> Int -> Either String Double
nextTokenCE = nextTokenCEGeneric

fullSequenceLogitsGeneric :: (Floating a, Ord a) => Config -> [a] -> [Int] -> Either String [[a]]
fullSequenceLogitsGeneric c params tokens = do
  _ <- validateInputs c params tokens
  layout <- namedLayout c
  embedding <- get "embedding" layout
  initial <- mapM (embeddingRow c embedding) tokens
  hidden <- foldM (runBlock c params layout) initial [0 .. layerCount c - 1]
  gain <- get "final_rms" layout
  let final = map (rmsNorm gain) hidden
  pure [map (dot h) (rows (modelDim c) embedding) | h <- final]
  where
    get name layout = case filter ((== name) . sliceName) layout of
      [s] -> sliceValues s params
      _ -> Left ("missing layout slice: " ++ name)

nextTokenCEGeneric :: (Floating a, Ord a) => Config -> [a] -> [Int] -> Int -> Either String a
nextTokenCEGeneric c params prefix target
  | null prefix = Left "next-token loss requires a non-empty prefix"
  | target < 0 || target >= vocabSize c = Left "target token out of range"
  | otherwise = do
      logits <- fullSequenceLogitsGeneric c params prefix
      let z = last logits
      pure (logSumExp z - z !! target)

-- Instrumented twin of the reference forward for the `act-stats`
-- diagnostic: the same math through the same helpers (rmsNorm, matVec,
-- glaAttention, causalAttention), plus per-block activation statistics.
-- Double-only and used by no training path; the conformance oracle keeps
-- the real forward honest, and this twin reuses its pieces so the
-- statistics describe the conformant denotation.
data BlockStats = BlockStats
  { blockStatsIndex :: !Int
  , blockStatsKind :: !String
  , blockStatsResidual :: !(Double, Double, Double)
    -- ^ output-residual RMS over the first 32 / middle / last 32 positions
  , blockStatsAttended :: !Double
    -- ^ RMS of the attention output (pre-Wo)
  , blockStatsCosEmbed :: !Double
    -- ^ mean cosine between the block output and the token's own embedding:
    -- the symmetry-dominance measurement (≈1 means the stream still denotes
    -- the current token, so the tied head sees a near-symmetric Gram logit)
  , blockStatsAlpha :: !(Maybe (Double, Double, Double))
    -- ^ GLA gates: (arithmetic mean, geometric mean, fraction above 0.9)
  }

data ActStats = ActStats
  { actEmbeddingRms :: !Double
  , actBlocks :: ![BlockStats]
  , actLogitRms :: !Double
  , actLogitMax :: !Double
  , actPTarget :: !Double
  , actLoss :: !Double
  }

fullSequenceStats :: Config -> [Double] -> [Int] -> Either String ActStats
fullSequenceStats c params tokens = do
  _ <- validateInputs c params tokens
  layout <- namedLayout c
  embedding <- getSlice "embedding" layout params
  initial <- mapM (embeddingRow c embedding) tokens
  (finalHidden, statsRev) <- foldM
    (\(xs, acc) i -> do
      (xs', stats) <- runBlockStats c params layout initial xs i
      pure (xs', stats : acc))
    (initial, [])
    [0 .. layerCount c - 1]
  gain <- getSlice "final_rms" layout params
  let final = map (rmsNorm gain) finalHidden
      logits = [map (dot h) (rows (modelDim c) embedding) | h <- final]
      scored = zip logits (drop 1 tokens)
      losses = [logSumExp z - z !! t | (z, t) <- scored]
      pTargets = [exp (z !! t - logSumExp z) | (z, t) <- scored]
  pure ActStats
    { actEmbeddingRms = rmsOfRows initial
    , actBlocks = reverse statsRev
    , actLogitRms = rmsOfRows logits
    , actLogitMax = maximum (0 : map (maximum . map abs) logits)
    , actPTarget = meanOf pTargets
    , actLoss = meanOf losses
    }

-- Statistics-carrying copy of runBlock; the math must stay line-for-line
-- equivalent to runBlock (any edit there belongs here too).
runBlockStats :: Config -> [Double] -> [Slice] -> [[Double]] -> [[Double]] -> Int -> Either String ([[Double]], BlockStats)
runBlockStats c params layout embedded xs blockIndex = do
  attGain <- get "rms_att"
  wq <- get "wq"
  wk <- get "wk"
  wv <- get "wv"
  wo <- get "wo"
  ffGain <- get "rms_ff"
  wgate <- get "wgate"
  wup <- get "wup"
  wdown <- get "wdown"
  let normalized = map (rmsNorm attGain) xs
      qs = map (matVec d d wq) normalized
      ks = map (matVec d d wk) normalized
      vs = map (matVec d d wv) normalized
  (attended, alphaStats) <-
    if isSoftmaxLayer c blockIndex
      then pure (causalAttention c qs ks vs, Nothing)
      else do
        walpha <- get "walpha"
        let alphas = map (map gateAlpha . matVec d d walpha) normalized
            flat = concat alphas
        pure ( glaAttendedOut c (glaAttention c qs ks vs alphas)
             , Just ( meanOf flat
                    , exp (meanOf (map log flat))
                    , fromIntegral (length (filter (> 0.9) flat))
                        / fromIntegral (max 1 (length flat))))
  let afterAttention = zipWith addVec xs (map (matVec d d wo) attended)
      ff x =
        let n = rmsNorm ffGain x
            gated = zipWith (*) (map silu (matVec f d wgate n)) (matVec f d wup n)
        in matVec d f wdown gated
      out = zipWith addVec afterAttention (map ff afterAttention)
      kind = if isSoftmaxLayer c blockIndex then "softmax" else "gla"
  pure ( out
       , BlockStats blockIndex kind (bucketRms out) (rmsOfRows attended)
           (meanCos out embedded) alphaStats)
  where
    d = modelDim c
    f = ffDim c
    prefix = "blocks." ++ show blockIndex ++ "."
    get suffix = case filter ((== prefix ++ suffix) . sliceName) layout of
      [s] -> sliceValues s params
      _ -> Left ("missing layout slice: " ++ prefix ++ suffix)

getSlice :: String -> [Slice] -> [Double] -> Either String [Double]
getSlice name layout params = case filter ((== name) . sliceName) layout of
  [s] -> sliceValues s params
  _ -> Left ("missing layout slice: " ++ name)

meanOf :: [Double] -> Double
meanOf [] = 0
meanOf xs = sum xs / fromIntegral (length xs)

rmsOfRows :: [[Double]] -> Double
rmsOfRows rowsOf =
  let flat = concat rowsOf
  in if null flat then 0 else sqrt (meanOf (map (\v -> v * v) flat))

bucketRms :: [[Double]] -> (Double, Double, Double)
bucketRms rowsOf =
  let n = length rowsOf
      firstB = take 32 rowsOf
      lastB = drop (max 0 (n - 32)) rowsOf
      midB = if n > 64 then take (n - 64) (drop 32 rowsOf) else rowsOf
  in (rmsOfRows firstB, rmsOfRows midB, rmsOfRows lastB)

meanCos :: [[Double]] -> [[Double]] -> Double
meanCos hs es = meanOf (zipWith cosine hs es)
  where
    cosine h e =
      let nh = sqrt (dot h h)
          ne = sqrt (dot e e)
      in if nh == 0 || ne == 0 then 0 else dot h e / (nh * ne)

validateInputs :: Config -> [a] -> [Int] -> Either String ()
validateInputs c params tokens = do
  _ <- validateConfig c
  if length params /= paramCount c
    then Left ("expected " ++ show (paramCount c) ++ " parameters, got " ++ show (length params))
    else pure ()
  if length tokens > contextSize c
    then Left "token sequence exceeds context"
    else pure ()
  if any (\t -> t < 0 || t >= vocabSize c) tokens
    then Left "token out of vocabulary"
    else pure ()

embeddingRow :: Config -> [a] -> Int -> Either String [a]
embeddingRow c table token
  | token < 0 || token >= vocabSize c = Left "token out of vocabulary"
  | otherwise = Right (take d (drop (token * d) table))
  where d = modelDim c

-- Hybrid token mixer (docs/RUN-2026-07-25-WIKI-FULL.md): GLA layers step a
-- per-head dk x dv state; every fourth layer is softmax full attention with
-- no positional encoding — position lives in the GLA gates.
runBlock :: (Floating a, Ord a) => Config -> [a] -> [Slice] -> [[a]] -> Int -> Either String [[a]]
runBlock c params layout xs blockIndex = do
  attGain <- get "rms_att"
  wq <- get "wq"
  wk <- get "wk"
  wv <- get "wv"
  wo <- get "wo"
  ffGain <- get "rms_ff"
  wgate <- get "wgate"
  wup <- get "wup"
  wdown <- get "wdown"
  let normalized = map (rmsNorm attGain) xs
      qs = map (matVec d d wq) normalized
      ks = map (matVec d d wk) normalized
      vs = map (matVec d d wv) normalized
  attended <-
    if isSoftmaxLayer c blockIndex
      then pure (causalAttention c qs ks vs)
      else do
        walpha <- get "walpha"
        let alphas = map (map gateAlpha . matVec d d walpha) normalized
        pure (glaAttendedOut c (glaAttention c qs ks vs alphas))
  let afterAttention = zipWith addVec xs (map (matVec d d wo) attended)
      ff x =
        let n = rmsNorm ffGain x
            gated = zipWith (*) (map silu (matVec f d wgate n)) (matVec f d wup n)
        in matVec d f wdown gated
  pure (zipWith addVec afterAttention (map ff afterAttention))
  where
    d = modelDim c
    f = ffDim c
    prefix = "blocks." ++ show blockIndex ++ "."
    get suffix = case filter ((== prefix ++ suffix) . sliceName) layout of
      [s] -> sliceValues s params
      _ -> Left ("missing layout slice: " ++ prefix ++ suffix)

rmsNorm :: Floating a => [a] -> [a] -> [a]
rmsNorm gain x = zipWith (\g xi -> g * xi / scale) gain x
  where
    n = fromIntegral (length x)
    scale = sqrt (sum (map (\v -> v * v) x) / n + 1e-5)

matVec :: Num a => Int -> Int -> [a] -> [a] -> [a]
matVec rowCount colCount matrix x =
  [dot (take colCount (drop (r * colCount) matrix)) x | r <- [0 .. rowCount - 1]]

rows :: Int -> [a] -> [[a]]
rows width xs
  | null xs = []
  | otherwise = take width xs : rows width (drop width xs)

dot :: Num a => [a] -> [a] -> a
dot a b = sum (zipWith (*) a b)

addVec :: Num a => [a] -> [a] -> [a]
addVec = zipWith (+)

silu :: Floating a => a -> a
silu x = x / (1 + exp (-x))

sigmoid :: Floating a => a -> a
sigmoid x = 1 / (1 + exp (-x))

-- Numerically stable log(sigmoid z) = -(max(-z,0) + log(1+exp(-|z|))),
-- written with primitives every Floating+Ord (including AD types) has.
logSigmoid :: (Floating a, Ord a) => a -> a
logSigmoid z = negate (max (negate z) 0 + log (1 + exp (negate (abs z))))

-- The GLA gate with temperature (FormalTransformer.Config.gateTemperature):
-- alpha = sigmoid(z)^(1/tau).  The tau == 1 branch keeps the historical
-- bit pattern for conformance against the recorded references.
gateAlpha :: (Floating a, Ord a) => a -> a
gateAlpha z
  | gateTemperature == 1 = sigmoid z
  | otherwise = exp (logSigmoid z / realToFrac gateTemperature)

-- Per-head L2 normalization of a full d-row, the same map q/k go through.
l2NormalizeHeads :: Floating a => Config -> [a] -> [a]
l2NormalizeHeads c x =
  concat [l2Normalize (take hd (drop (h * hd) x)) | h <- [0 .. headCount c - 1]]
  where hd = headDim c

-- FormalTransformer.Config.glaOutputNorm: normalize the GLA attended
-- output (pre-Wo) per head, or pass it through unchanged.
glaAttendedOut :: Floating a => Config -> [[a]] -> [[a]]
glaAttendedOut c attended
  | glaOutputNorm = map (l2NormalizeHeads c) attended
  | otherwise = attended

l2Normalize :: Floating a => [a] -> [a]
l2Normalize x = map (/ norm) x
  where norm = sqrt (sum (map (\v -> v * v) x) + 1e-6)

-- Gated linear attention in the RECURRENT form — the definitional reading of
-- the semantics (FormalTransformer/Attention/Linear.agda stepGLA/runGLA):
-- per head, S_t = diag(alpha_t) * S_{t-1} + k_t v_t^T and o_t = q_t^T S_t.
-- The Futhark implementation computes the PARALLEL closed form; their
-- agreement in the conformance oracle is the f32 shadow of the proved
-- recurrent≡parallel theorem.  Queries and keys are L2-normalized per head
-- to bound the state readout.
glaAttention :: Floating a => Config -> [[a]] -> [[a]] -> [[a]] -> [[a]] -> [[a]]
glaAttention c qs ks vs alphas = map concat (transpose perHead)
  where
    hd = headDim c
    perHead = [ headOutputs h | h <- [0 .. headCount c - 1] ]
    headSlice vector h = take hd (drop (h * hd) vector)
    headOutputs h = go zeroState (zip4' qh kh vh ah)
      where
        qh = map (l2Normalize . (`headSlice` h)) qs
        kh = map (l2Normalize . (`headSlice` h)) ks
        vh = map (`headSlice` h) vs
        ah = map (`headSlice` h) alphas
        zeroState = replicate hd (replicate hd 0)
        go _ [] = []
        go state ((q, k, v, alpha) : rest) =
          let state' = zipWith3
                (\ac kc row -> zipWith (\s vj -> ac * s + kc * vj) row v)
                alpha k state
              out = [ sum (zipWith (*) q col) | col <- transpose state' ]
          in out : go state' rest

zip4' :: [a] -> [b] -> [c] -> [d] -> [(a, b, c, d)]
zip4' (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4' as bs cs ds
zip4' _ _ _ _ = []

-- Softmax full attention, no positional encoding.
causalAttention :: (Floating a, Ord a) => Config -> [[a]] -> [[a]] -> [[a]] -> [[a]]
causalAttention c qs ks vs =
  [ concat
      [ let qh = headSlice q h
            sourceKeys = map (\vector -> headSlice vector h) (take (t + 1) ks)
            sourceValues = map (\vector -> headSlice vector h) (take (t + 1) vs)
            scores = map (\kh -> dot qh kh / sqrt (fromIntegral hd)) sourceKeys
            weights = softmax scores
        in foldl addVec (replicate hd 0) (zipWith (\w value -> map (w *) value) weights sourceValues)
      | h <- [0 .. headCount c - 1]
      ]
  | (t, q) <- zip [0 ..] qs
  ]
  where
    hd = headDim c
    headSlice vector h = take hd (drop (h * hd) vector)

logSumExp :: (Floating a, Ord a) => [a] -> a
logSumExp [] = error "logSumExp: empty input"
logSumExp xs = m + log (sum (map (exp . subtract m) xs))
  where m = maximum xs

softmax :: (Floating a, Ord a) => [a] -> [a]
softmax [] = []
softmax xs = map (/ total) shifted
  where
    m = maximum xs
    shifted = map (exp . subtract m) xs
    total = sum shifted
