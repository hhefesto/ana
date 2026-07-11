module FormalTransformer.Model
  ( fullSequenceLogits
  , nextTokenCE
  , fullSequenceLogitsGeneric
  , nextTokenCEGeneric
  , logSumExp
  , softmax
  ) where

import Control.Monad (foldM)
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
      qs = zipWith (rope c) [0 ..] (map (matVec d d wq) normalized)
      ks = zipWith (rope c) [0 ..] (map (matVec d d wk) normalized)
      vs = map (matVec d d wv) normalized
      attended = causalAttention c qs ks vs
      afterAttention = zipWith addVec xs (map (matVec d d wo) attended)
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

rope :: Floating a => Config -> Int -> [a] -> [a]
rope c position vector = concatMap rotateHead (rows hd vector)
  where
    hd = headDim c
    rotateHead h = concat
      [ let x = h !! (2 * i)
            y = h !! (2 * i + 1)
            theta = fromIntegral position / (10000 ** (fromIntegral (2 * i) / fromIntegral hd))
        in [x * cos theta - y * sin theta, x * sin theta + y * cos theta]
      | i <- [0 .. hd `div` 2 - 1]
      ]

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
