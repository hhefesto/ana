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
import FormalTransformer.Attention.Gla (glaAttention)
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
  unembedding <- if tiedHead c then pure embedding else get "unembedding" layout
  initial <- mapM (embeddingRow c embedding) tokens
  hidden <- foldM (runBlock c params layout) initial [0 .. layerCount c - 1]
  gain <- get "final_rms" layout
  let final = map (rmsNorm gain) hidden
  pure [map (dot h) (rows (modelDim c) unembedding) | h <- final]
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
  unembedding <- if tiedHead c then pure embedding
                 else getSlice "unembedding" layout params
  initial <- mapM (embeddingRow c embedding) tokens
  (finalHidden, statsRev) <- foldM
    (\(xs, acc) i -> do
      (xs', stats) <- runBlockStats c params layout initial xs i
      pure (xs', stats : acc))
    (initial, [])
    [0 .. layerCount c - 1]
  gain <- getSlice "final_rms" layout params
  let final = map (rmsNorm gain) finalHidden
      logits = [map (dot h) (rows (modelDim c) unembedding) | h <- final]
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

-- The diagnostic view of a block.  It used to be a hand-copied twin of
-- runBlock carrying the comment "the math must stay line-for-line equivalent
-- to runBlock (any edit there belongs here too)" -- with nothing checking
-- that.  Both now call runBlockTrace, so the claim is true by construction
-- rather than by discipline.
runBlockStats :: Config -> [Double] -> [Slice] -> [[Double]] -> [[Double]] -> Int -> Either String ([[Double]], BlockStats)
runBlockStats c params layout embedded xs blockIndex = do
  weights <- blockWeights c params layout blockIndex
  let trace = runBlockTrace c weights xs
      out = traceOut trace
      attended = traceAttended trace
      alphaStats = fmap gateStats (traceAlphas trace)
      gateStats alphas =
        let flat = concat alphas
        in ( meanOf flat
           , exp (meanOf (map log flat))
           , fromIntegral (length (filter (> 0.9) flat))
               / fromIntegral (max 1 (length flat)))
      kind = case blockMixer weights of { SoftmaxMixer _ -> "softmax"; GlaMixer _ -> "gla" }
  pure ( out
       , BlockStats blockIndex kind (bucketRms out) (rmsOfRows attended)
           (meanCos out embedded) alphaStats)

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

-- A block's parameters.  Everything but the token mixer is uniform across
-- layer kinds, so that is where the sum type belongs: a GlaMixer cannot lack
-- its gate projection and a SoftmaxMixer cannot carry one, which is the
-- invariant Layout.namedLayout enforces by hand when it emits `walpha` for
-- GLA blocks only.  The Bool that used to decide this at three separate call
-- sites is now decided once, where the weights are fetched.  The gate
-- parametrization (Config.gateKind) follows the same rule: an RG-LRU gate
-- cannot lack its per-channel decay base, so it carries it.
data Mixer a = SoftmaxMixer (SoftmaxExtras a) | GlaMixer (GlaGate a)

data GlaGate a
  = SigmoidGate [a]      -- walpha
  | RgLruGate [a] [a]    -- walpha, gate_lambda

-- The v3 softmax-layer arms (Config.qkNorm / Config.headSinks), fetched
-- only when enabled so a v2 config carries exactly the v2 weights.
data SoftmaxExtras a = SoftmaxExtras
  { qkGains :: Maybe ([a], [a])  -- zero-centered: gain = 1 + w, w decayed
  , sinkLogits :: Maybe [a]      -- one learned logit per head
  }

data BlockWeights a = BlockWeights
  { blockAttGain :: [a]
  , blockWq :: [a]
  , blockWk :: [a]
  , blockWv :: [a]
  , blockWo :: [a]
  , blockMixer :: Mixer a
  , blockFfGain :: [a]
  , blockWgate :: [a]
  , blockWup :: [a]
  , blockWdown :: [a]
  }

blockWeights :: Config -> [a] -> [Slice] -> Int -> Either String (BlockWeights a)
blockWeights c params layout blockIndex = do
  attGain <- get "rms_att"
  wq <- get "wq"
  wk <- get "wk"
  wv <- get "wv"
  wo <- get "wo"
  mixer <- case layerKind c blockIndex of
    SoftmaxKind -> do
      gains <- if qkNorm c
        then Just <$> ((,) <$> get "qk_gain_q" <*> get "qk_gain_k")
        else pure Nothing
      sinks <- if headSinks c then Just <$> get "sink" else pure Nothing
      pure (SoftmaxMixer (SoftmaxExtras gains sinks))
    GlaKind -> case gateKind c of
      GateSigmoid -> GlaMixer . SigmoidGate <$> get "walpha"
      GateRgLru ->
        (\w l -> GlaMixer (RgLruGate w l)) <$> get "walpha" <*> get "gate_lambda"
  ffGain <- get "rms_ff"
  wgate <- get "wgate"
  wup <- get "wup"
  wdown <- get "wdown"
  pure (BlockWeights attGain wq wk wv wo mixer ffGain wgate wup wdown)
  where
    prefix = "blocks." ++ show blockIndex ++ "."
    get suffix = case filter ((== prefix ++ suffix) . sliceName) layout of
      [s] -> sliceValues s params
      _ -> Left ("missing layout slice: " ++ prefix ++ suffix)

-- The intermediates a diagnostic needs, so that runBlock and runBlockStats
-- can share one definition of the math instead of two copies of it.
data BlockTrace a = BlockTrace
  { traceOut :: [[a]]
  , traceAttended :: [[a]]
  , traceAlphas :: Maybe [[a]]
  }

-- Hybrid token mixer (docs/RUN-2026-07-25-WIKI-FULL.md): GLA layers step a
-- per-head dk x dv state; every fourth layer is softmax full attention with
-- no positional encoding — position lives in the GLA gates.
--
-- Every float expression here is character-for-character what runBlock and
-- runBlockStats computed separately; only the fetching of the weights and the
-- kind test moved out, into blockWeights.  The fields of BlockTrace are lazy,
-- so runBlock still evaluates exactly what it did before.
runBlockTrace :: (Floating a, Ord a) => Config -> BlockWeights a -> [[a]] -> BlockTrace a
runBlockTrace c weights xs = BlockTrace out attended alphas
  where
    d = modelDim c
    f = ffDim c
    normalized = map (rmsNorm (blockAttGain weights)) xs
    qs = map (matVec d d (blockWq weights)) normalized
    ks = map (matVec d d (blockWk weights)) normalized
    vs = map (matVec d d (blockWv weights)) normalized
    (alphas, attended) = case blockMixer weights of
      SoftmaxMixer extras -> (Nothing, causalAttention c extras qs ks vs)
      GlaMixer gate ->
        let (as, scales) = glaGates c gate normalized
        in (Just as, glaAttention c qs ks vs as scales)
    afterAttention = zipWith addVec xs (map (matVec d d (blockWo weights)) attended)
    ff x =
      let n = rmsNorm (blockFfGain weights) x
          gated = zipWith (*) (map silu (matVec f d (blockWgate weights) n)) (matVec f d (blockWup weights) n)
      in matVec d f (blockWdown weights) gated
    out = zipWith addVec afterAttention (map ff afterAttention)

runBlock :: (Floating a, Ord a) => Config -> [a] -> [Slice] -> [[a]] -> Int -> Either String [[a]]
runBlock c params layout xs blockIndex = do
  weights <- blockWeights c params layout blockIndex
  pure (traceOut (runBlockTrace c weights xs))

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

-- The GLA gate, dispatched on the architecture (Config.gateKind).  The
-- sigmoid case keeps the v2 bit pattern for conformance against the
-- recorded references.  The RG-LRU case is not a scalar map — its alpha
-- pairs the projected logit with the per-channel decay base gate_lambda —
-- so it lives in glaGates, where the block has the weights; this scalar
-- entry point rejects it loudly rather than silently approximating.
gateAlpha :: (Floating a, Ord a) => Config -> a -> a
gateAlpha c z = case gateKind c of
  GateSigmoid -> sigmoid z
  GateRgLru -> error "gateAlpha: GateRgLru needs gate_lambda (per-channel); use glaGates"

-- Gate semantics per parametrization, over the normalized block input:
-- (alphas, write scales), both position-major and d-wide.
--
--   SigmoidGate  alpha = sigmoid(walpha x), unit write (Nothing keeps the
--                v2 float path textually identical).
--   RgLruGate    Griffin's RG-LRU (arXiv 2402.19427, design notes §3.7):
--                per channel, log alpha = c · sigmoid(z) · log sigmoid(Λ)
--                with c = 8 — the exponent reshapes the response so
--                moderate pre-activations already yield near-1 decay — and
--                the state write is scaled by sqrt(1 − alpha²), computed
--                from the log-gate as sqrt(1 − exp(2·log alpha)), so an
--                open gate does not let fresh input swamp held state.
--                That coupling is what the measured tau = 16 arm lacked
--                when it opened the gates and lost on loss (Config.hs
--                history, run/gate-arms-2026-07-31).
glaGates :: (Floating a, Ord a) => Config -> GlaGate a -> [[a]] -> ([[a]], Maybe [[a]])
glaGates c (SigmoidGate walpha) normalized =
  (map (map sigmoid . matVec d d walpha) normalized, Nothing)
  where d = modelDim c
glaGates c (RgLruGate walpha lam) normalized =
  ( map (map exp) logAlphas
  , Just (map (map (\la -> sqrt (1 - exp (2 * la)))) logAlphas) )
  where
    d = modelDim c
    logAlphas =
      map (zipWith (\l z -> 8 * sigmoid z * logSigmoid l) lam . matVec d d walpha)
        normalized

-- Softmax full attention, no positional encoding.  The v3 arms:
--
--   qkGains      per-head RMSNorm on q and k before the scores, with
--                zero-centered gains (gain = 1 + w, w weight-decayed —
--                the Qwen3-Next fix for gain drift; notes §3.4).  Bounds
--                every logit by construction: |score| ≤ |gain|²·hd/√hd.
--   sinkLogits   one learned logit per head, appended to the scores; the
--                softmax runs over scores ++ [sink] and the sink's weight
--                is dropped — exactly the restriction-of-extended-softmax
--                semantics proved in FormalTransformer/Attention/Sink.agda
--                (token weights are a subdistribution, deficient by the
--                sink's share), so a head can attend to nothing.
causalAttention :: (Floating a, Ord a) => Config -> SoftmaxExtras a -> [[a]] -> [[a]] -> [[a]] -> [[a]]
causalAttention c extras qs ks vs =
  [ concat
      [ let qh = normQ (headSlice q h)
            sourceKeys = map (normK . (\vector -> headSlice vector h)) (take (t + 1) ks)
            sourceValues = map (\vector -> headSlice vector h) (take (t + 1) vs)
            scores = map (\kh -> dot qh kh / sqrt (fromIntegral hd)) sourceKeys
            weights = case sinkLogits extras of
              Nothing -> softmax scores
              Just sinks -> init (softmax (scores ++ [sinks !! h]))
        in foldl addVec (replicate hd 0) (zipWith (\w value -> map (w *) value) weights sourceValues)
      | h <- [0 .. headCount c - 1]
      ]
  | (t, q) <- zip [0 ..] qs
  ]
  where
    hd = headDim c
    headSlice vector h = take hd (drop (h * hd) vector)
    (normQ, normK) = case qkGains extras of
      Nothing -> (id, id)
      Just (wq, wk) -> (rmsNorm (map (1 +) wq), rmsNorm (map (1 +) wk))

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
