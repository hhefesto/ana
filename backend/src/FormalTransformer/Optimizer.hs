{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Optimizer
  ( AdamWConfig (..)
  , AdamWState (..)
  , validateAdamWConfig
  , initAdamW
  , learningRate
  , adamWStep
  , MuonConfig (..)
  , OptimizerConfig (..)
  , OptimizerState (..)
  , validateOptimizerConfig
  , initOptimizerState
  , MuonSlice (..)
  , newtonSchulz
  , muonStep
  ) where

import Data.Binary (Binary, get, put)
import Data.List (transpose)
import qualified Data.Vector.Unboxed as VU
import GHC.Generics (Generic)

data AdamWConfig = AdamWConfig
  { baseLearningRate :: !Double
  , beta1 :: !Double
  , beta2 :: !Double
  , adamEpsilon :: !Double
  , weightDecay :: !Double
  , warmupSteps :: !Int
  , totalSteps :: !Int
  } deriving (Eq, Show, Generic)

instance Binary AdamWConfig

-- The moments are one Double per parameter, so at GPT-2-small scale each is
-- 115M elements. As a boxed [Double] that is 4.6 GB per moment -- 40 bytes an
-- element, against 8 in an unboxed vector -- and a checkpoint holds three such
-- arrays at once. Representation, not denotation: the optimizer is still the
-- same function of the same Doubles.
data AdamWState = AdamWState
  { adamStep :: !Int
  , firstMoment :: !(VU.Vector Double)
  , secondMoment :: !(VU.Vector Double)
  } deriving (Eq, Show, Generic)

-- The moments encode as length-prefixed lists — the same bytes a derived
-- vector instance would produce, streamed without materializing a boxed
-- list on the write side.
instance Binary AdamWState where
  put state = do
    put (adamStep state)
    put (VU.toList (firstMoment state))
    put (VU.toList (secondMoment state))
  get = do
    step <- get
    first <- get
    second <- get
    pure (AdamWState step (VU.fromList first) (VU.fromList second))

validateAdamWConfig :: AdamWConfig -> Either String AdamWConfig
validateAdamWConfig cfg
  | any nonFinite [baseLearningRate cfg, beta1 cfg, beta2 cfg, adamEpsilon cfg, weightDecay cfg] =
      Left "AdamW floating-point configuration values must be finite"
  | baseLearningRate cfg < 0 = Left "base learning rate must be nonnegative"
  | beta1 cfg < 0 || beta1 cfg >= 1 || beta2 cfg < 0 || beta2 cfg >= 1 = Left "Adam betas must be in [0,1)"
  | adamEpsilon cfg <= 0 = Left "Adam epsilon must be positive"
  | weightDecay cfg < 0 = Left "weight decay must be nonnegative"
  | warmupSteps cfg < 0 = Left "warmup steps must be nonnegative"
  | totalSteps cfg <= 0 = Left "total steps must be positive"
  | warmupSteps cfg > totalSteps cfg = Left "warmup steps must not exceed total steps"
  | otherwise = Right cfg
  where nonFinite value = isNaN value || isInfinite value

initAdamW :: Int -> AdamWState
initAdamW n = AdamWState 0 (VU.replicate n 0) (VU.replicate n 0)

learningRate :: AdamWConfig -> Int -> Double
learningRate cfg step
  | step <= 0 = 0
  | warmupSteps cfg > 0 && step <= warmupSteps cfg =
      baseLearningRate cfg * fromIntegral step / fromIntegral (warmupSteps cfg)
  | totalSteps cfg <= warmupSteps cfg = baseLearningRate cfg
  | otherwise = baseLearningRate cfg * 0.5 * (1 + cos (pi * progress))
  where
    elapsed = max 0 (min (totalSteps cfg - warmupSteps cfg) (step - warmupSteps cfg))
    progress = fromIntegral elapsed / fromIntegral (totalSteps cfg - warmupSteps cfg)

-- Muon (Jordan et al.; Moonshot arXiv 2502.16982, design notes §3.3):
-- steepest descent under the spectral norm for the 2-D hidden matrices,
-- via 5 Newton-Schulz iterations of an odd quintic that pushes the
-- momentum's singular values toward 1 while preserving singular vectors.
-- Everything that is not a hidden matrix (embedding/head, norm gains,
-- gate_lambda, sinks) stays on AdamW.  The update-RMS rescale
-- 0.2·sqrt(max(rows, cols)) makes AdamW learning rates carry over
-- unchanged (Moonshot's RMS matching), and weight decay stays decoupled,
-- exactly as in adamWStep.
data MuonConfig = MuonConfig
  { muonBeta :: !Double  -- momentum coefficient (0.95)
  } deriving (Eq, Show, Generic)

instance Binary MuonConfig

-- The run's optimizer: AdamW throughout, optionally with Muon on the
-- hidden matrices.  Stored in the checkpoint manifest and validated on
-- resume like every other piece of the run identity.
data OptimizerConfig = OptimizerConfig
  { optAdamW :: !AdamWConfig
  , optMuon :: !(Maybe MuonConfig)
  } deriving (Eq, Show, Generic)

instance Binary OptimizerConfig

validateOptimizerConfig :: OptimizerConfig -> Either String OptimizerConfig
validateOptimizerConfig cfg = do
  _ <- validateAdamWConfig (optAdamW cfg)
  case optMuon cfg of
    Nothing -> Right cfg
    Just muon
      | muonBeta muon < 0 || muonBeta muon >= 1 -> Left "Muon momentum must be in [0,1)"
      | otherwise -> Right cfg

-- AdamW moments plus (under Muon) one momentum vector.  The momentum is
-- full-length with zeros on the AdamW-owned entries, and the AdamW
-- moments hold zeros on the Muon-owned entries: one canonical
-- representation, so checkpoint bytes are a function of the trajectory.
data OptimizerState = OptimizerState
  { optAdamWState :: !AdamWState
  , optMuonMomentum :: !(Maybe (VU.Vector Double))
  } deriving (Eq, Show, Generic)

instance Binary OptimizerState where
  put state = do
    put (optAdamWState state)
    case optMuonMomentum state of
      Nothing -> put False
      Just momentum -> put True >> put (VU.toList momentum)
  get = do
    adam <- get
    hasMomentum <- get
    momentum <- if hasMomentum then Just . VU.fromList <$> get else pure Nothing
    pure (OptimizerState adam momentum)

initOptimizerState :: OptimizerConfig -> Int -> OptimizerState
initOptimizerState cfg n = OptimizerState (initAdamW n)
  (fmap (const (VU.replicate n 0)) (optMuon cfg))

-- One Muon-owned matrix: offset into the flat vector and its shape
-- (Layout.Slice carries both; rows*cols elements, row-major).
data MuonSlice = MuonSlice
  { muonOffset :: !Int
  , muonRows :: !Int
  , muonCols :: !Int
  } deriving (Eq, Show)

-- Five iterations of the odd quintic X ← aX + (bA + cA²)X with A = XXᵀ,
-- coefficients (3.4445, −4.7750, 2.0315), on the Frobenius-normalized
-- input; iterate on the transpose when rows > cols so A is the small
-- Gram side.  Orthogonal equivariance makes the two orientations agree
-- in exact arithmetic.
newtonSchulz :: Int -> Int -> [Double] -> [Double]
newtonSchulz rows cols flat
  | rows > cols = concat (transpose (go (transpose (chunk cols flat))))
  | otherwise = concat (go (chunk cols flat))
  where
    chunk width xs = case splitAt width xs of
      (row, []) -> [row]
      (row, rest) -> row : chunk width rest
    fro m = sqrt (sum [x * x | row <- m, x <- row])
    matmul x y =
      let yt = transpose y
      in [[sum (zipWith (*) xr yc) | yc <- yt] | xr <- x]
    go m0 =
      let x0 = map (map (/ (fro m0 + 1e-7))) m0
          iteration x =
            let a = matmul x (transpose x)
                b = zipWith (zipWith (\p q -> (-4.7750) * p + 2.0315 * q)) a (matmul a a)
                bx = matmul b x
            in zipWith (zipWith (\xe be -> 3.4445 * xe + be)) x bx
      in iterate iteration x0 !! 5

-- The combined step: AdamW on every parameter outside the Muon slices,
-- and on each Muon slice the Nesterov-momentum Newton-Schulz update
--   m' = β·m + g;  O = NS₅(g + β·m');  p ← p − lr·(0.2·√max(r,c)·O + wd·p).
-- The same learning-rate schedule drives both parts.
muonStep
  :: OptimizerConfig
  -> [MuonSlice]
  -> VU.Vector Bool
  -> OptimizerState
  -> VU.Vector Double
  -> VU.Vector Double
  -> Either String (VU.Vector Double, OptimizerState)
muonStep cfg slices decay state params gradients = do
  _ <- validateOptimizerConfig cfg
  muonCfg <- maybe (Left "muonStep needs optMuon") Right (optMuon cfg)
  momentum0 <- maybe (Left "muonStep needs a momentum vector") Right (optMuonMomentum state)
  let n = VU.length params
      adamState = optAdamWState state
      acfg = optAdamW cfg
      beta = muonBeta muonCfg
  if any (/= n) [ VU.length decay, VU.length gradients, VU.length momentum0
                , VU.length (firstMoment adamState), VU.length (secondMoment adamState) ]
    then Left "muonStep vectors must have identical lengths"
    else Right ()
  if adamStep adamState < 0 then Left "step must be nonnegative" else Right ()
  if adamStep adamState >= totalSteps acfg
    then Left "step has reached the configured total steps" else Right ()
  let step = adamStep adamState + 1
      lr = learningRate acfg step
      muonMask = VU.update (VU.replicate n False)
        (VU.fromList [ (muonOffset s + i, True)
                     | s <- slices, i <- [0 .. muonRows s * muonCols s - 1] ])
      momentum' = VU.imap
        (\i mu -> if muonMask VU.! i then beta * mu + gradients VU.! i else 0)
        momentum0
      m = VU.imap
        (\i old -> if muonMask VU.! i then 0
                   else beta1 acfg * old + (1 - beta1 acfg) * (gradients VU.! i))
        (firstMoment adamState)
      v = VU.imap
        (\i old -> if muonMask VU.! i then 0
                   else let g = gradients VU.! i
                        in beta2 acfg * old + (1 - beta2 acfg) * g * g)
        (secondMoment adamState)
      b1Correction = 1 - beta1 acfg ** fromIntegral step
      b2Correction = 1 - beta2 acfg ** fromIntegral step
      adamUpdated = VU.imap
        (\i p ->
          if muonMask VU.! i then p
          else p - lr * ((m VU.! i) / b1Correction
                          / (sqrt ((v VU.! i) / b2Correction) + adamEpsilon acfg)
                 + (if decay VU.! i then weightDecay acfg * p else 0)))
        params
      applySlice acc s =
        let count = muonRows s * muonCols s
            off = muonOffset s
            gSlice = VU.toList (VU.slice off count gradients)
            muSlice = VU.toList (VU.slice off count momentum')
            nsIn = zipWith (\g mu -> g + beta * mu) gSlice muSlice
            o = newtonSchulz (muonRows s) (muonCols s) nsIn
            scale = 0.2 * sqrt (fromIntegral (max (muonRows s) (muonCols s)))
            upd = [ ( off + i
                    , let p = acc VU.! (off + i)
                      in p - lr * (scale * oi
                           + (if decay VU.! (off + i) then weightDecay acfg * p else 0)) )
                  | (i, oi) <- zip [0 ..] o ]
        in acc VU.// upd
      updated = foldl applySlice adamUpdated slices
  pure ( updated
       , OptimizerState (AdamWState step m v) (Just momentum') )

adamWStep
  :: AdamWConfig
  -> VU.Vector Bool
  -> AdamWState
  -> VU.Vector Double
  -> VU.Vector Double
  -> Either String (VU.Vector Double, AdamWState)
adamWStep cfg decay state params gradients
  | Left message <- validateAdamWConfig cfg = Left message
  | any (/= n) [ VU.length decay, VU.length (firstMoment state)
               , VU.length (secondMoment state), VU.length gradients ] =
      Left "AdamW vectors must have identical lengths"
  | adamStep state < 0 = Left "AdamW step must be nonnegative"
  | adamStep state >= totalSteps cfg = Left "AdamW step has reached the configured total steps"
  | otherwise = Right (updated, AdamWState step m v)
  where
    n = VU.length params
    step = adamStep state + 1
    lr = learningRate cfg step
    m = VU.zipWith (\old g -> beta1 cfg * old + (1 - beta1 cfg) * g) (firstMoment state) gradients
    v = VU.zipWith (\old g -> beta2 cfg * old + (1 - beta2 cfg) * g * g) (secondMoment state) gradients
    b1Correction = 1 - beta1 cfg ** fromIntegral step
    b2Correction = 1 - beta2 cfg ** fromIntegral step
    update p mi vi shouldDecay =
      p - lr * (mi / b1Correction / (sqrt (vi / b2Correction) + adamEpsilon cfg)
        + (if shouldDecay then weightDecay cfg * p else 0))
    updated = VU.zipWith4 update params m v decay
