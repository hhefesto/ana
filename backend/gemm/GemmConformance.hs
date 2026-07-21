module Main (main) where

import Control.Monad (unless)
import Buffer
import Data.Int (Int64)
import Decomposed
import FormalTransformer.Config
import FormalTransformer.Layout
import FormalTransformer.Model
import Numeric.AD (grad)
import Parameters
import PiecesConformance
import System.Environment (lookupEnv)
import System.Exit (die)

config :: Config
config = Config 5 4 4 6 5 2

tokens :: [Int]
tokens = [0, 2, 3, 4]

batchTokens :: [[Int]]
batchTokens = [tokens, [0, 3, 2, 4]]

parameters :: [Double]
parameters = either error (concatMap initialize) (namedLayout config)
  where
    initialize slice
      | sliceDecay slice = [0.025 * sin (fromIntegral (sliceOffset slice + i + 1) * 0.73) | i <- [0 .. sliceLength slice - 1]]
      | otherwise = replicate (sliceLength slice) 1

main :: IO ()
main = do
  parameterViewSmoke
  withContext $ \ctx -> do
    pieceSmoke ctx
    dataMovementSmoke ctx
    oracleSmoke ctx
    putStrLn "gemm conformance: initial piece/oracle smoke passed"

parameterViewSmoke :: IO ()
parameterViewSmoke = do
  buffer <- bufferFromList (map realToFrac parameters)
  views <- either die pure (parameterViews config buffer)
  assertShape "embedding view" (vocabSize config) (modelDim config) (paramsEmbedding views)
  assertShape "final RMS view" 1 (modelDim config) (paramsFinalRms views)
  case paramsBlocks views of
    [b0, b1, b2, b3, b4] -> do
      mapM_ assertGlaBlock [(0, b0), (1, b1), (2, b2), (4, b4)]
      assertSoftmaxBlock 3 b3
    blocks -> die ("expected 5 block parameter views, got " ++ show (length blocks))

pieceSmoke :: Context -> IO ()
pieceSmoke ctx = do
  rmsNormSmoke ctx
  l2NormHeadsSmoke ctx
  siluGateSmoke ctx
  feedForwardSmoke ctx
  softmaxAttentionSmoke ctx
  softmaxAttentionSubBlockSmoke ctx
  softmaxFullBlockSmoke ctx
  glaAttentionSmoke ctx
  glaFullBlockSmoke ctx
  withF32 ctx (replicate (1 * 3 * 2) 0) $ \logitsArr ->
    withI64 ctx [0, 1, 0] $ \tokenArr -> do
      loss1 <- pieceCeLoss ctx 1 3 2 1 logitsArr tokenArr
      loss2 <- pieceCeLoss ctx 1 3 2 2 logitsArr tokenArr
      compareScalar "piece CE effective batch" 1e-6 1e-6 (2 * realToFrac loss2) (realToFrac loss1)
      gradient <- pieceCeGradient ctx (1 * 3 * 2) 1 3 2 1 1 logitsArr tokenArr
      compareVector "piece CE gradient" 1e-6 1e-6 [0.25, -0.25, -0.25, 0.25, 0, 0] (map realToFrac gradient)
  withI64 ctx [1, 1, 0] $ \tokenArr ->
    withF32 ctx [1, 2, 3, 4, 5, 6] $ \barArr -> do
      scattered <- pieceEmbeddingScatter ctx (3 * 2) 3 2 3 tokenArr barArr
      compareVector "piece embedding scatter-add" 1e-6 1e-6 [5, 6, 4, 6, 0, 0] (map realToFrac scattered)

rmsNormSmoke :: Context -> IO ()
rmsNormSmoke ctx = do
  let rows = 2
      dim = 3
      x = [1, -2, 3, 0.5, -1.5, 2.5] :: [Double]
      gain = [0.75, -1.25, 2] :: [Double]
      outputBar = [0.2, -0.3, 0.5, 1.5, -0.25, 0.75] :: [Double]
      expected = concatMap (uncurry rmsNormRow) (zip (chunksOf dim x) (repeat gain))
      scalarX xs = sum (zipWith (*) (concatMap (uncurry rmsNormRow)
        (zip (chunksOf dim xs) (repeat (map realToFrac gain)))) (map realToFrac outputBar))
      scalarGain gs = sum (zipWith (*) (concatMap (uncurry rmsNormRow)
        (zip (chunksOf dim (map realToFrac x)) (repeat gs))) (map realToFrac outputBar))
      expectedXBar = grad scalarX x
      expectedGainBar = grad scalarGain gain
  withF32 ctx (map realToFrac x) $ \xArr ->
    withF32 ctx (map realToFrac gain) $ \gainArr -> do
      actual <- pieceRmsNorm ctx (rows * dim) (fromIntegral rows) (fromIntegral dim) xArr gainArr
      compareVector "piece RMS norm forward" 1e-6 1e-6 expected (map realToFrac actual)
      withF32 ctx (map realToFrac outputBar) $ \barArr -> do
        (actualXBar, actualGainBar) <- pieceRmsNormBackward ctx (rows * dim) dim
          (fromIntegral rows) (fromIntegral dim) xArr gainArr barArr
        compareVector "piece RMS norm x pullback" 1e-5 1e-5 expectedXBar (map realToFrac actualXBar)
        compareVector "piece RMS norm gain pullback" 1e-5 1e-5 expectedGainBar (map realToFrac actualGainBar)

rmsNormRow :: Floating a => [a] -> [a] -> [a]
rmsNormRow xs gain = zipWith (\g x -> g * x / scale) gain xs
  where
    scale = sqrt (sum (map (\x -> x * x) xs) / fromIntegral (length xs) + 1e-5)

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)

l2NormHeadsSmoke :: Context -> IO ()
l2NormHeadsSmoke ctx = do
  let rows = 2
      dim = 6
      heads = 3
      x = [1, -2, 0.5, 3, -1, 2, 0.25, -0.75, 1.5, -2.5, 3.5, -4.5] :: [Double]
      outputBar = [0.5, -0.25, 1.25, -1.5, 0.75, 2, -1, 0.3, -0.6, 1.7, -2.1, 0.9] :: [Double]
      expected = concatMap (l2NormalizeHeads heads) (chunksOf dim x)
      scalar xs = sum (zipWith (*) (concatMap (l2NormalizeHeads heads) (chunksOf dim xs)) (map realToFrac outputBar))
      expectedBar = grad scalar x
  withF32 ctx (map realToFrac x) $ \xArr -> do
    actual <- pieceL2NormHeads ctx (rows * dim) (fromIntegral rows)
      (fromIntegral dim) (fromIntegral heads) xArr
    compareVector "piece L2 head norm forward" 1e-6 1e-6 expected (map realToFrac actual)
    withF32 ctx (map realToFrac outputBar) $ \barArr -> do
      actualBar <- pieceL2NormHeadsBackward ctx (rows * dim) (fromIntegral rows)
        (fromIntegral dim) (fromIntegral heads) xArr barArr
      compareVector "piece L2 head norm pullback" 1e-5 1e-5 expectedBar (map realToFrac actualBar)

l2NormalizeHeads :: Floating a => Int -> [a] -> [a]
l2NormalizeHeads heads xs = concatMap l2Normalize (chunksOf headWidth xs)
  where
    headWidth = length xs `div` heads

l2Normalize :: Floating a => [a] -> [a]
l2Normalize xs = map (/ norm) xs
  where
    norm = sqrt (sum (map (\x -> x * x) xs) + 1e-6)

siluGateSmoke :: Context -> IO ()
siluGateSmoke ctx = do
  let gate = [-2, -0.5, 0, 0.75, 3, 1.25] :: [Double]
      up = [0.25, -1.5, 2, 0.5, -0.75, 1.2] :: [Double]
      outputBar = [1, -0.2, 0.4, 2, -1.1, 0.3] :: [Double]
      expected = zipWith siluGate gate up
      scalarGate gs = sum (zipWith (*) (zipWith siluGate gs (map realToFrac up))
        (map realToFrac outputBar))
      scalarUp us = sum (zipWith (*) (zipWith siluGate (map realToFrac gate) us)
        (map realToFrac outputBar))
      expectedGateBar = grad scalarGate gate
      expectedUpBar = grad scalarUp up
      count = length gate
  withF32 ctx (map realToFrac gate) $ \gateArr ->
    withF32 ctx (map realToFrac up) $ \upArr -> do
      actual <- pieceSiluGate ctx count gateArr upArr
      compareVector "piece SwiGLU forward" 1e-6 1e-6 expected (map realToFrac actual)
      withF32 ctx (map realToFrac outputBar) $ \barArr -> do
        (actualGateBar, actualUpBar) <- pieceSiluGateBackward ctx count gateArr upArr barArr
        compareVector "piece SwiGLU gate pullback" 1e-5 1e-5 expectedGateBar
          (map realToFrac actualGateBar)
        compareVector "piece SwiGLU up pullback" 1e-5 1e-5 expectedUpBar
          (map realToFrac actualUpBar)

siluGate :: Floating a => a -> a -> a
siluGate gate up = gate / (1 + exp (-gate)) * up

feedForwardSmoke :: Context -> IO ()
feedForwardSmoke ctx = do
  let rows = 2
      d = 4
      f = 6
      x = values 8 0.31
      gain = values 4 0.47
      wgate = values 24 0.19
      wup = values 24 0.23
      wdown = values 24 0.29
      outputBar = values 8 0.37
      expected = feedForwardReference d f x gain wgate wup wdown
      scalarX xs = dotList (feedForwardReference d f xs
        (map realToFrac gain) (map realToFrac wgate) (map realToFrac wup)
        (map realToFrac wdown)) (map realToFrac outputBar)
      scalarGain gs = dotList (feedForwardReference d f (map realToFrac x)
        gs (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
        (map realToFrac outputBar)
      scalarWgate ws = dotList (feedForwardReference d f (map realToFrac x)
        (map realToFrac gain) ws (map realToFrac wup) (map realToFrac wdown))
        (map realToFrac outputBar)
      scalarWup ws = dotList (feedForwardReference d f (map realToFrac x)
        (map realToFrac gain) (map realToFrac wgate) ws (map realToFrac wdown))
        (map realToFrac outputBar)
      scalarWdown ws = dotList (feedForwardReference d f (map realToFrac x)
        (map realToFrac gain) (map realToFrac wgate) (map realToFrac wup) ws)
        (map realToFrac outputBar)
  actual <- feedForwardDecomposed (conformancePieceOps ctx) rows d f
    (map realToFrac x) (map realToFrac gain) (map realToFrac wgate)
    (map realToFrac wup) (map realToFrac wdown) (map realToFrac outputBar)
  compareVector "decomposed FF forward" 2e-5 2e-5 expected
    (map realToFrac (ffOutput actual))
  compareVector "decomposed FF x pullback" 3e-5 3e-5 (grad scalarX x)
    (map realToFrac (ffXBar actual))
  compareVector "decomposed FF gain pullback" 3e-5 3e-5 (grad scalarGain gain)
    (map realToFrac (ffGainBar actual))
  compareVector "decomposed FF wgate pullback" 3e-5 3e-5 (grad scalarWgate wgate)
    (map realToFrac (ffWgateBar actual))
  compareVector "decomposed FF wup pullback" 3e-5 3e-5 (grad scalarWup wup)
    (map realToFrac (ffWupBar actual))
  compareVector "decomposed FF wdown pullback" 3e-5 3e-5 (grad scalarWdown wdown)
    (map realToFrac (ffWdownBar actual))
  where
    values :: Int -> Double -> [Double]
    values count frequency =
      [0.4 * sin (fromIntegral (i + 1) * frequency) | i <- [0 .. count - 1]]

rmsList :: Context -> Int -> Int -> [Float] -> [Float] -> IO [Float]
rmsList ctx rows d x gain =
  withF32 ctx x $ \xArr ->
    withF32 ctx gain $ \gainArr ->
      pieceRmsNorm ctx (rows * d) (fromIntegral rows) (fromIntegral d) xArr gainArr

rmsBackwardList :: Context -> Int -> Int -> [Float] -> [Float] -> [Float] -> IO ([Float], [Float])
rmsBackwardList ctx rows d x gain outputBar =
  withF32 ctx x $ \xArr ->
    withF32 ctx gain $ \gainArr ->
      withF32 ctx outputBar $ \barArr ->
        pieceRmsNormBackward ctx (rows * d) d (fromIntegral rows)
          (fromIntegral d) xArr gainArr barArr

l2HeadsList :: Context -> Int -> Int -> Int -> [Float] -> IO [Float]
l2HeadsList ctx rows d heads x =
  withF32 ctx x $ pieceL2NormHeads ctx (rows * d) (fromIntegral rows)
    (fromIntegral d) (fromIntegral heads)

l2HeadsBackwardList :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
l2HeadsBackwardList ctx rows d heads x outputBar =
  withF32 ctx x $ \xArr ->
    withF32 ctx outputBar $ pieceL2NormHeadsBackward ctx (rows * d)
      (fromIntegral rows) (fromIntegral d) (fromIntegral heads) xArr

siluGateList :: Context -> [Float] -> [Float] -> IO [Float]
siluGateList ctx gate up =
  withF32 ctx gate $ \gateArr ->
    withF32 ctx up $ \upArr -> pieceSiluGate ctx (length gate) gateArr upArr

siluGateBackwardList :: Context -> [Float] -> [Float] -> [Float] -> IO ([Float], [Float])
siluGateBackwardList ctx gate up outputBar =
  withF32 ctx gate $ \gateArr ->
    withF32 ctx up $ \upArr ->
      withF32 ctx outputBar $ \barArr ->
        pieceSiluGateBackward ctx (length gate) gateArr upArr barArr

addList :: Context -> [Float] -> [Float] -> IO [Float]
addList ctx x y =
  withF32 ctx x $ \xArr ->
    withF32 ctx y $ \yArr -> pieceAdd ctx (length x) xArr yArr

addBackwardList :: Context -> [Float] -> IO ([Float], [Float])
addBackwardList ctx outputBar =
  withF32 ctx outputBar $ pieceAddBackward ctx (length outputBar)

conformancePieceOps :: Context -> PieceOps [Float] [Int64]
conformancePieceOps ctx = PieceOps
  { opsDenseForward = denseForwardList
  , opsDenseBackward = densePullbackList
  , opsBatchedGemmForward = batchedGemmList
  , opsBatchedGemmBackward = batchedGemmPullbackList
  , opsRmsForward = rmsList ctx
  , opsRmsBackward = rmsBackwardList ctx
  , opsL2HeadsForward = l2HeadsList ctx
  , opsL2HeadsBackward = l2HeadsBackwardList ctx
  , opsSiluGateForward = siluGateList ctx
  , opsSiluGateBackward = siluGateBackwardList ctx
  , opsAddForward = addList ctx
  , opsAddBackward = addBackwardList ctx
  , opsSplitHeadsForward = splitHeadsList ctx
  , opsSplitHeadsBackward = splitHeadsBackwardList ctx
  , opsMergeHeadsForward = mergeHeadsList ctx
  , opsMergeHeadsBackward = mergeHeadsBackwardList ctx
  , opsCausalSoftmaxForward = causalSoftmaxList ctx
  , opsCausalSoftmaxBackward = causalSoftmaxBackwardList ctx
  , opsGateCumForward = gateCumList ctx
  , opsGateCumBackward = gateCumBackwardList ctx
  , opsQkDecayForward = qkDecayList ctx
  , opsQkDecayBackward = qkDecayBackwardList ctx
  , opsGlaIntraForward = glaIntraList ctx
  , opsGlaIntraBackward = glaIntraBackwardList ctx
  , opsStateAdvanceForward = stateAdvanceList ctx
  , opsStateAdvanceBackward = stateAdvanceBackwardList ctx
  , opsEmbeddingGather = embeddingGatherList ctx
  , opsEmbeddingBackward = embeddingBackwardList ctx
  , opsCeForward = ceForwardList ctx
  , opsCeBackward = ceBackwardList ctx
  , opsZeros = \count -> pure (replicate count 0)
  , opsLength = length
  , opsTokenCount = length
  , opsFree = const (pure ())
  , opsReadSlice = \offset count values -> pure (readSliceList offset count values)
  , opsWriteSlice = \offset destination source ->
      pure (writeSliceList offset destination source)
  , opsGatherChunk = \groups chunkCount elements chunkIndex values ->
      pure (gatherChunk groups chunkCount elements chunkIndex values)
  , opsPutChunk = \groups chunkCount elements chunkIndex destination source ->
      pure (putChunkList groups chunkCount elements chunkIndex destination source)
  }

-- The data-movement entries must reproduce the pure list references exactly:
-- they move bytes, so the tolerance is zero. Cases cover offset zero, interior,
-- and tail slices, the first and last chunk index, and single-chunk layouts.
dataMovementSmoke :: Context -> IO ()
dataMovementSmoke ctx = do
  let asDouble = map realToFrac :: [Float] -> [Double]
      source13 = [fromIntegral i * 0.5 - 3 | i <- [1 :: Int .. 13]] :: [Float]
      patch = [fromIntegral i * 0.25 + 40 | i <- [1 :: Int .. 5]] :: [Float]
      grouped groups chunkCount elements =
        [ fromIntegral i * 0.125 - 7
        | i <- [1 :: Int .. groups * chunkCount * elements]
        ] :: [Float]
  sequence_
    [ do
        actual <- withF32 ctx source13 $
          pieceReadSlice ctx count 13 (fromIntegral offset) (fromIntegral count)
        compareVector
          ("piece read_slice offset=" ++ show offset ++ " count=" ++ show count)
          0 0 (asDouble (readSliceList offset count source13)) (asDouble actual)
    | (offset, count) <- [(0, 5), (4, 6), (8, 5), (3, 0)]
    ]
  sequence_
    [ do
        actual <- withF32 ctx source13 $ \destination ->
          withF32 ctx patch $
            pieceWriteSlice ctx 13 13 (fromIntegral (length patch))
              (fromIntegral offset) destination
        compareVector ("piece write_slice offset=" ++ show offset) 0 0
          (asDouble (writeSliceList offset source13 patch)) (asDouble actual)
    | offset <- [0, 4, 8]
    ]
  sequence_
    [ do
        let values = grouped groups chunkCount elements
            expected = gatherChunk groups chunkCount elements chunkIndex values
        actual <- withF32 ctx values $
          pieceGatherChunk ctx (groups * elements) (fromIntegral groups)
            (fromIntegral chunkCount) (fromIntegral elements)
            (fromIntegral chunkIndex)
        compareVector
          ("piece gather_chunk " ++ show (groups, chunkCount, elements, chunkIndex))
          0 0 (asDouble expected) (asDouble actual)
        let replacement =
              [fromIntegral i * 0.0625 + 90 | i <- [1 :: Int .. groups * elements]]
            expectedPut =
              putChunkList groups chunkCount elements chunkIndex values replacement
        actualPut <- withF32 ctx values $ \destination ->
          withF32 ctx replacement $
            piecePutChunk ctx (groups * chunkCount * elements)
              (fromIntegral groups) (fromIntegral chunkCount)
              (fromIntegral elements) (fromIntegral chunkIndex) destination
        compareVector
          ("piece put_chunk " ++ show (groups, chunkCount, elements, chunkIndex))
          0 0 (asDouble expectedPut) (asDouble actualPut)
    | (groups, chunkCount, elements, chunkIndex) <-
        [(3, 4, 5, 0), (3, 4, 5, 2), (3, 4, 5, 3), (2, 1, 6, 0), (1, 5, 2, 4)]
    ]

feedForwardReference
  :: Floating a
  => Int
  -> Int
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
feedForwardReference d f x gain wgate wup wdown =
  zipWith (+) x projected
  where
    normalized = concatMap (`rmsNormRow` gain) (chunksOf d x)
    gate = denseReference d f normalized wgate
    up = denseReference d f normalized wup
    hidden = zipWith siluGate gate up
    projected = denseReference f d hidden wdown

denseReference :: Num a => Int -> Int -> [a] -> [a] -> [a]
denseReference inputDim outputDim x weights = concatMap project (chunksOf inputDim x)
  where
    weightRows = take outputDim (chunksOf inputDim weights)
    project row = map (dotList row) weightRows

dotList :: Num a => [a] -> [a] -> a
dotList left right = sum (zipWith (*) left right)

softmaxAttentionSmoke :: Context -> IO ()
softmaxAttentionSmoke ctx = do
  let batch = 2
      n = 3
      heads = 2
      hd = 2
      count = batch * n * heads * hd
      q = values count 0.17
      k = values count 0.29
      value = values count 0.41
      outputBar = values count 0.53
      expected = softmaxAttentionReference batch n heads hd q k value
      scalarQ qs = dotList (softmaxAttentionReference batch n heads hd qs
        (map realToFrac k) (map realToFrac value)) (map realToFrac outputBar)
      scalarK ks = dotList (softmaxAttentionReference batch n heads hd
        (map realToFrac q) ks (map realToFrac value)) (map realToFrac outputBar)
      scalarV vs = dotList (softmaxAttentionReference batch n heads hd
        (map realToFrac q) (map realToFrac k) vs) (map realToFrac outputBar)
  actual <- softmaxAttentionDecomposed (conformancePieceOps ctx) batch n heads hd
    (map realToFrac q) (map realToFrac k) (map realToFrac value)
    (map realToFrac outputBar)
  compareVector "decomposed softmax attention forward" 3e-5 3e-5 expected
    (map realToFrac (softmaxOutput actual))
  compareVector "decomposed softmax attention Q pullback" 5e-5 5e-5 (grad scalarQ q)
    (map realToFrac (softmaxQBar actual))
  compareVector "decomposed softmax attention K pullback" 5e-5 5e-5 (grad scalarK k)
    (map realToFrac (softmaxKBar actual))
  compareVector "decomposed softmax attention V pullback" 5e-5 5e-5 (grad scalarV value)
    (map realToFrac (softmaxVBar actual))
  where
    values :: Int -> Double -> [Double]
    values count frequency =
      [0.35 * cos (fromIntegral (i + 1) * frequency) | i <- [0 .. count - 1]]

softmaxAttentionSubBlockSmoke :: Context -> IO ()
softmaxAttentionSubBlockSmoke ctx = do
  let batch = 2
      n = 3
      heads = 2
      hd = 2
      d = heads * hd
      rows = batch * n
      x = values (rows * d) 0.13
      gain = values d 0.21
      wq = values (d * d) 0.27
      wk = values (d * d) 0.33
      wv = values (d * d) 0.39
      wo = values (d * d) 0.45
      outputBar = values (rows * d) 0.51
      expected = softmaxAttentionSubBlockReference batch n heads hd x gain wq wk wv wo
      scalarX xs = dotList (softmaxAttentionSubBlockReference batch n heads hd xs
        (map realToFrac gain) (map realToFrac wq) (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo)) (map realToFrac outputBar)
      scalarGain gs = dotList (softmaxAttentionSubBlockReference batch n heads hd
        (map realToFrac x) gs (map realToFrac wq) (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo)) (map realToFrac outputBar)
      scalarWq ws = dotList (softmaxAttentionSubBlockReference batch n heads hd
        (map realToFrac x) (map realToFrac gain) ws (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo)) (map realToFrac outputBar)
      scalarWk ws = dotList (softmaxAttentionSubBlockReference batch n heads hd
        (map realToFrac x) (map realToFrac gain) (map realToFrac wq) ws
        (map realToFrac wv) (map realToFrac wo)) (map realToFrac outputBar)
      scalarWv ws = dotList (softmaxAttentionSubBlockReference batch n heads hd
        (map realToFrac x) (map realToFrac gain) (map realToFrac wq)
        (map realToFrac wk) ws (map realToFrac wo)) (map realToFrac outputBar)
      scalarWo ws = dotList (softmaxAttentionSubBlockReference batch n heads hd
        (map realToFrac x) (map realToFrac gain) (map realToFrac wq)
        (map realToFrac wk) (map realToFrac wv) ws) (map realToFrac outputBar)
  actual <- softmaxAttentionSubBlockDecomposed (conformancePieceOps ctx) batch n heads hd
    (map realToFrac x) (map realToFrac gain) (map realToFrac wq)
    (map realToFrac wk) (map realToFrac wv) (map realToFrac wo)
    (map realToFrac outputBar)
  compareVector "decomposed softmax sub-block forward" 5e-5 5e-5 expected
    (map realToFrac (softmaxBlockOutput actual))
  compareVector "decomposed softmax sub-block X pullback" 8e-5 8e-5 (grad scalarX x)
    (map realToFrac (softmaxBlockXBar actual))
  compareVector "decomposed softmax sub-block RMS pullback" 8e-5 8e-5 (grad scalarGain gain)
    (map realToFrac (softmaxBlockGainBar actual))
  compareVector "decomposed softmax sub-block Wq pullback" 8e-5 8e-5 (grad scalarWq wq)
    (map realToFrac (softmaxBlockWqBar actual))
  compareVector "decomposed softmax sub-block Wk pullback" 8e-5 8e-5 (grad scalarWk wk)
    (map realToFrac (softmaxBlockWkBar actual))
  compareVector "decomposed softmax sub-block Wv pullback" 8e-5 8e-5 (grad scalarWv wv)
    (map realToFrac (softmaxBlockWvBar actual))
  compareVector "decomposed softmax sub-block Wo pullback" 8e-5 8e-5 (grad scalarWo wo)
    (map realToFrac (softmaxBlockWoBar actual))
  where
    values :: Int -> Double -> [Double]
    values count frequency =
      [0.3 * sin (fromIntegral (i + 1) * frequency) | i <- [0 .. count - 1]]

softmaxFullBlockSmoke :: Context -> IO ()
softmaxFullBlockSmoke ctx = do
  let batch = 2
      n = 3
      heads = 2
      hd = 2
      d = heads * hd
      f = 6
      rows = batch * n
      x = values (rows * d) 0.11
      rmsAtt = values d 0.17
      wq = values (d * d) 0.23
      wk = values (d * d) 0.29
      wv = values (d * d) 0.31
      wo = values (d * d) 0.37
      rmsFf = values d 0.41
      wgate = values (f * d) 0.43
      wup = values (f * d) 0.47
      wdown = values (d * f) 0.53
      outputBar = values (rows * d) 0.59
      expected = softmaxFullBlockReference batch n heads hd f x rmsAtt
        wq wk wv wo rmsFf wgate wup wdown
      objective output = dotList output (map realToFrac outputBar)
      scalarX xs = objective (softmaxFullBlockReference batch n heads hd f xs
        (map realToFrac rmsAtt) (map realToFrac wq) (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo) (map realToFrac rmsFf)
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
      scalarRmsAtt gain = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) gain (map realToFrac wq) (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo) (map realToFrac rmsFf)
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
      scalarWq weights = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) weights (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo) (map realToFrac rmsFf)
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
      scalarWk weights = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) (map realToFrac wq) weights
        (map realToFrac wv) (map realToFrac wo) (map realToFrac rmsFf)
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
      scalarWv weights = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) (map realToFrac wq)
        (map realToFrac wk) weights (map realToFrac wo) (map realToFrac rmsFf)
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
      scalarWo weights = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) (map realToFrac wq)
        (map realToFrac wk) (map realToFrac wv) weights (map realToFrac rmsFf)
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
      scalarRmsFf gain = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) (map realToFrac wq)
        (map realToFrac wk) (map realToFrac wv) (map realToFrac wo) gain
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown))
      scalarWgate weights = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) (map realToFrac wq)
        (map realToFrac wk) (map realToFrac wv) (map realToFrac wo)
        (map realToFrac rmsFf) weights (map realToFrac wup) (map realToFrac wdown))
      scalarWup weights = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) (map realToFrac wq)
        (map realToFrac wk) (map realToFrac wv) (map realToFrac wo)
        (map realToFrac rmsFf) (map realToFrac wgate) weights (map realToFrac wdown))
      scalarWdown weights = objective (softmaxFullBlockReference batch n heads hd f
        (map realToFrac x) (map realToFrac rmsAtt) (map realToFrac wq)
        (map realToFrac wk) (map realToFrac wv) (map realToFrac wo)
        (map realToFrac rmsFf) (map realToFrac wgate) (map realToFrac wup) weights)
      actualWeights = SoftmaxBlockWeights
        (map realToFrac rmsAtt) (map realToFrac wq) (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo) (map realToFrac rmsFf)
        (map realToFrac wgate) (map realToFrac wup) (map realToFrac wdown)
  actual <- softmaxBlockDecomposed (conformancePieceOps ctx) batch n heads hd f
    (map realToFrac x) actualWeights (map realToFrac outputBar)
  compareVector "decomposed full softmax block forward" 8e-5 8e-5 expected
    (map realToFrac (fullSoftmaxOutput actual))
  compareVector "decomposed full softmax block X pullback" 1e-4 1e-4 (grad scalarX x)
    (map realToFrac (fullSoftmaxXBar actual))
  compareVector "decomposed full softmax block rms_att pullback" 1e-4 1e-4
    (grad scalarRmsAtt rmsAtt) (map realToFrac (fullSoftmaxRmsAttBar actual))
  compareVector "decomposed full softmax block Wq pullback" 1e-4 1e-4
    (grad scalarWq wq) (map realToFrac (fullSoftmaxWqBar actual))
  compareVector "decomposed full softmax block Wk pullback" 1e-4 1e-4
    (grad scalarWk wk) (map realToFrac (fullSoftmaxWkBar actual))
  compareVector "decomposed full softmax block Wv pullback" 1e-4 1e-4
    (grad scalarWv wv) (map realToFrac (fullSoftmaxWvBar actual))
  compareVector "decomposed full softmax block Wo pullback" 1e-4 1e-4
    (grad scalarWo wo) (map realToFrac (fullSoftmaxWoBar actual))
  compareVector "decomposed full softmax block rms_ff pullback" 1e-4 1e-4
    (grad scalarRmsFf rmsFf) (map realToFrac (fullSoftmaxRmsFfBar actual))
  compareVector "decomposed full softmax block Wgate pullback" 1e-4 1e-4
    (grad scalarWgate wgate) (map realToFrac (fullSoftmaxWgateBar actual))
  compareVector "decomposed full softmax block Wup pullback" 1e-4 1e-4
    (grad scalarWup wup) (map realToFrac (fullSoftmaxWupBar actual))
  compareVector "decomposed full softmax block Wdown pullback" 1e-4 1e-4
    (grad scalarWdown wdown) (map realToFrac (fullSoftmaxWdownBar actual))
  where
    values :: Int -> Double -> [Double]
    values count frequency =
      [0.25 * cos (fromIntegral (i + 1) * frequency) | i <- [0 .. count - 1]]

softmaxAttentionSubBlockReference
  :: (Floating a, Ord a)
  => Int
  -> Int
  -> Int
  -> Int
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
softmaxAttentionSubBlockReference batch n heads hd x gain wq wk wv wo =
  zipWith (+) x projected
  where
    d = heads * hd
    normalized = concatMap (`rmsNormRow` gain) (chunksOf d x)
    q = denseReference d d normalized wq
    k = denseReference d d normalized wk
    value = denseReference d d normalized wv
    attended = softmaxAttentionReference batch n heads hd q k value
    projected = denseReference d d attended wo

softmaxFullBlockReference
  :: (Floating a, Ord a)
  => Int
  -> Int
  -> Int
  -> Int
  -> Int
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
softmaxFullBlockReference batch n heads hd f x rmsAtt wq wk wv wo rmsFf wgate wup wdown =
  feedForwardReference d f afterAttention rmsFf wgate wup wdown
  where
    d = heads * hd
    afterAttention = softmaxAttentionSubBlockReference batch n heads hd
      x rmsAtt wq wk wv wo

splitHeadsList :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
splitHeadsList ctx batch n heads hd x =
  withF32 ctx x $ pieceSplitHeads ctx (length x) (fromIntegral batch)
    (fromIntegral n) (fromIntegral heads) (fromIntegral hd)

splitHeadsBackwardList :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
splitHeadsBackwardList ctx batch n heads hd outputBar =
  withF32 ctx outputBar $ pieceSplitHeadsBackward ctx (length outputBar)
    (fromIntegral batch) (fromIntegral n) (fromIntegral heads) (fromIntegral hd)

mergeHeadsList :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
mergeHeadsList ctx batch n heads hd x =
  withF32 ctx x $ pieceMergeHeads ctx (length x) (fromIntegral batch)
    (fromIntegral n) (fromIntegral heads) (fromIntegral hd)

mergeHeadsBackwardList :: Context -> Int -> Int -> Int -> Int -> [Float] -> IO [Float]
mergeHeadsBackwardList ctx batch n heads hd outputBar =
  withF32 ctx outputBar $ pieceMergeHeadsBackward ctx (length outputBar)
    (fromIntegral batch) (fromIntegral n) (fromIntegral heads) (fromIntegral hd)

causalSoftmaxList :: Context -> Int -> Int -> Int -> [Float] -> IO [Float]
causalSoftmaxList ctx groups n hd scores =
  withF32 ctx scores $ pieceCausalSoftmax ctx (length scores) (fromIntegral groups)
    (fromIntegral n) (fromIntegral hd)

causalSoftmaxBackwardList :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> IO [Float]
causalSoftmaxBackwardList ctx groups n hd scores weightsBar =
  withF32 ctx scores $ \scoresArr ->
    withF32 ctx weightsBar $ pieceCausalSoftmaxBackward ctx (length scores)
      (fromIntegral groups) (fromIntegral n) (fromIntegral hd) scoresArr

gateCumList :: Context -> Int -> Int -> Int -> [Float] -> IO ([Float], [Float])
gateCumList ctx groups chunk hd gateLogits =
  withF32 ctx gateLogits $ pieceGateCum ctx groups chunk hd

gateCumBackwardList
  :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float] -> IO [Float]
gateCumBackwardList ctx groups chunk hd gateLogits relBar decBar =
  withF32 ctx gateLogits $ \gateArr ->
    withF32 ctx relBar $ \relBarArr ->
      withF32 ctx decBar $ pieceGateCumBackward ctx groups chunk hd gateArr relBarArr

qkDecayList
  :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float] -> [Float]
  -> IO ([Float], [Float])
qkDecayList ctx groups chunk hd q k rel dec =
  withF32 ctx q $ \qArr ->
    withF32 ctx k $ \kArr ->
      withF32 ctx rel $ \relArr ->
        withF32 ctx dec $ pieceQkDecay ctx groups chunk hd qArr kArr relArr

qkDecayBackwardList
  :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float] -> [Float]
  -> [Float] -> [Float] -> IO ([Float], [Float], [Float], [Float])
qkDecayBackwardList ctx groups chunk hd q k rel dec qScaledBar kScaledBar =
  withF32 ctx q $ \qArr ->
    withF32 ctx k $ \kArr ->
      withF32 ctx rel $ \relArr ->
        withF32 ctx dec $ \decArr ->
          withF32 ctx qScaledBar $ \qBarArr ->
            withF32 ctx kScaledBar $
              pieceQkDecayBackward ctx groups chunk hd qArr kArr relArr decArr qBarArr

glaIntraList
  :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float] -> [Float]
  -> IO [Float]
glaIntraList ctx groups chunk hd q k value rel =
  withF32 ctx q $ \qArr ->
    withF32 ctx k $ \kArr ->
      withF32 ctx value $ \valueArr ->
        withF32 ctx rel $ pieceGlaIntra ctx groups chunk hd qArr kArr valueArr

glaIntraBackwardList
  :: Context -> Int -> Int -> Int -> [Float] -> [Float] -> [Float] -> [Float]
  -> [Float] -> IO ([Float], [Float], [Float], [Float])
glaIntraBackwardList ctx groups chunk hd q k value rel outputBar =
  withF32 ctx q $ \qArr ->
    withF32 ctx k $ \kArr ->
      withF32 ctx value $ \valueArr ->
        withF32 ctx rel $ \relArr ->
          withF32 ctx outputBar $
            pieceGlaIntraBackward ctx groups chunk hd qArr kArr valueArr relArr

stateAdvanceList
  :: Context -> Int -> Int -> [Float] -> [Float] -> [Float] -> IO [Float]
stateAdvanceList ctx groups hd state contribution dec =
  withF32 ctx state $ \stateArr ->
    withF32 ctx contribution $ \contributionArr ->
      withF32 ctx dec $ pieceStateAdvance ctx groups hd stateArr contributionArr

stateAdvanceBackwardList
  :: Context -> Int -> Int -> [Float] -> [Float] -> [Float] -> [Float]
  -> IO ([Float], [Float], [Float])
stateAdvanceBackwardList ctx groups hd state contribution dec outputBar =
  withF32 ctx state $ \stateArr ->
    withF32 ctx contribution $ \contributionArr ->
      withF32 ctx dec $ \decArr ->
        withF32 ctx outputBar $
          pieceStateAdvanceBackward ctx groups hd stateArr contributionArr decArr

embeddingGatherList :: Context -> Int -> Int -> [Float] -> [Int64] -> IO [Float]
embeddingGatherList ctx vocab d embedding tokenValues =
  withF32 ctx embedding $ \embeddingArr ->
    withI64 ctx tokenValues $ pieceEmbeddingGather ctx (length tokenValues * d)
      (fromIntegral vocab) (fromIntegral d) (fromIntegral (length tokenValues)) embeddingArr

embeddingBackwardList :: Context -> Int -> Int -> [Int64] -> [Float] -> IO [Float]
embeddingBackwardList ctx vocab d tokenValues outputBar =
  withI64 ctx tokenValues $ \tokenArr ->
    withF32 ctx outputBar $ pieceEmbeddingScatter ctx (vocab * d)
      (fromIntegral vocab) (fromIntegral d) (fromIntegral (length tokenValues)) tokenArr

ceForwardList :: Context -> Int -> Int -> Int -> Int -> [Float] -> [Int64] -> IO Float
ceForwardList ctx batch n vocab effectiveBatch logitsValues tokenValues =
  withF32 ctx logitsValues $ \logitsArr ->
    withI64 ctx tokenValues $ pieceCeLoss ctx (fromIntegral batch) (fromIntegral n)
      (fromIntegral vocab) (fromIntegral effectiveBatch) logitsArr

ceBackwardList
  :: Context -> Int -> Int -> Int -> Int -> Float -> [Float] -> [Int64] -> IO [Float]
ceBackwardList ctx batch n vocab effectiveBatch seed logitsValues tokenValues =
  withF32 ctx logitsValues $ \logitsArr ->
    withI64 ctx tokenValues $ pieceCeGradient ctx (batch * n * vocab)
      (fromIntegral batch) (fromIntegral n) (fromIntegral vocab)
      (fromIntegral effectiveBatch) seed logitsArr

softmaxAttentionReference
  :: (Floating a, Ord a)
  => Int
  -> Int
  -> Int
  -> Int
  -> [a]
  -> [a]
  -> [a]
  -> [a]
softmaxAttentionReference batch n heads hd q k value = concat
  [ concat
      [ concat
          [ attentionHead i headIndex qRow kRows valueRows
          | headIndex <- [0 .. heads - 1]
          ]
      | (i, qRow) <- zip [0 :: Int ..] qRows
      ]
  | (qBatch, kBatch, valueBatch) <- zip3 qBatches kBatches valueBatches
  , let qRows = chunksOf d qBatch
        kRows = chunksOf d kBatch
        valueRows = chunksOf d valueBatch
  ]
  where
    d = heads * hd
    qBatches = take batch (chunksOf (n * d) q)
    kBatches = take batch (chunksOf (n * d) k)
    valueBatches = take batch (chunksOf (n * d) value)
    headSlice headIndex = take hd . drop (headIndex * hd)
    attentionHead i headIndex qRow kRows valueRows =
      foldl' (zipWith (+)) (replicate hd 0)
        (zipWith (\weight row -> map (weight *) (headSlice headIndex row))
          weights (take (i + 1) valueRows))
      where
        qHead = headSlice headIndex qRow
        scores = map ((/ sqrt (fromIntegral hd)) . dotList qHead . headSlice headIndex)
          (take (i + 1) kRows)
        weights = softmaxReference scores

softmaxReference :: (Floating a, Ord a) => [a] -> [a]
softmaxReference [] = []
softmaxReference (x : xs) = map (/ total) shifted
  where
    maximumValue = foldl' max x xs
    shifted = map (exp . subtract maximumValue) (x : xs)
    total = sum shifted

glaAttentionSmoke :: Context -> IO ()
glaAttentionSmoke ctx = do
  let batch = 2
      n = 10
      heads = 2
      hd = 2
      chunk = 2
      count = batch * n * heads * hd
      q = values count 0.07
      k = values count 0.11
      value = values count 0.13
      gate = map (subtract 0.4) (values count 0.17)
      outputBar = values count 0.19
      expected = glaAttentionReference batch n heads hd q k value gate
      objective output = dotList output (map realToFrac outputBar)
      scalarQ qs = objective (glaAttentionReference batch n heads hd qs
        (map realToFrac k) (map realToFrac value) (map realToFrac gate))
      scalarK ks = objective (glaAttentionReference batch n heads hd
        (map realToFrac q) ks (map realToFrac value) (map realToFrac gate))
      scalarV vs = objective (glaAttentionReference batch n heads hd
        (map realToFrac q) (map realToFrac k) vs (map realToFrac gate))
      scalarGate gates = objective (glaAttentionReference batch n heads hd
        (map realToFrac q) (map realToFrac k) (map realToFrac value) gates)
  actual <- glaAttentionDecomposed (conformancePieceOps ctx) batch n heads hd chunk
    (map realToFrac q) (map realToFrac k) (map realToFrac value)
    (map realToFrac gate) (map realToFrac outputBar)
  compareVector "decomposed GLA nc>4 forward" 1e-4 1e-4 expected
    (map realToFrac (glaOutput actual))
  compareVector "decomposed GLA nc>4 Q pullback" 2e-4 2e-4 (grad scalarQ q)
    (map realToFrac (glaQBar actual))
  compareVector "decomposed GLA nc>4 K pullback" 2e-4 2e-4 (grad scalarK k)
    (map realToFrac (glaKBar actual))
  compareVector "decomposed GLA nc>4 V pullback" 2e-4 2e-4 (grad scalarV value)
    (map realToFrac (glaVBar actual))
  compareVector "decomposed GLA nc>4 gate pullback" 2e-4 2e-4 (grad scalarGate gate)
    (map realToFrac (glaGateBar actual))
  where
    values :: Int -> Double -> [Double]
    values count frequency =
      [0.3 * sin (fromIntegral (i + 1) * frequency) | i <- [0 .. count - 1]]

glaAttentionReference
  :: (Floating a, Ord a)
  => Int
  -> Int
  -> Int
  -> Int
  -> [a]
  -> [a]
  -> [a]
  -> [a]
  -> [a]
glaAttentionReference batch n heads hd q k value gate = concat
  [ concat (foldl' (zipWith (++)) (replicate n [])
      [ runHead headIndex qRows kRows valueRows gateRows
      | headIndex <- [0 .. heads - 1]
      ])
  | (qBatch, kBatch, valueBatch, gateBatch) <- zip4Lists
      qBatches kBatches valueBatches gateBatches
  , let qRows = chunksOf d qBatch
        kRows = chunksOf d kBatch
        valueRows = chunksOf d valueBatch
        gateRows = chunksOf d gateBatch
  ]
  where
    d = heads * hd
    qBatches = take batch (chunksOf (n * d) q)
    kBatches = take batch (chunksOf (n * d) k)
    valueBatches = take batch (chunksOf (n * d) value)
    gateBatches = take batch (chunksOf (n * d) gate)
    headSlice headIndex = take hd . drop (headIndex * hd)
    runHead headIndex qRows kRows valueRows gateRows =
      go (replicate hd (replicate hd 0))
        (zip4Lists (map (headSlice headIndex) qRows)
          (map (headSlice headIndex) kRows)
          (map (headSlice headIndex) valueRows)
          (map (headSlice headIndex) gateRows))
    go _ [] = []
    go state ((qRow, kRow, valueRow, gateRow) : rest) =
      output : go state' rest
      where
        alpha = map gateAlpha gateRow
        state' = zipWith3
          (\decay key stateRow -> zipWith (\old valueElement ->
            decay * old + key * valueElement) stateRow valueRow)
          alpha kRow state
        output =
          [ sum (zipWith (\query stateElement -> query * stateElement)
              qRow (map (\row -> indexDefault 0 row column) state'))
          | column <- [0 .. hd - 1]
          ]

zip4Lists :: [a] -> [b] -> [c] -> [d] -> [(a, b, c, d)]
zip4Lists (a : as) (b : bs) (c : cs) (d : ds) =
  (a, b, c, d) : zip4Lists as bs cs ds
zip4Lists _ _ _ _ = []

indexDefault :: a -> [a] -> Int -> a
indexDefault fallback values index = case drop index values of
  value : _ -> value
  [] -> fallback

glaFullBlockSmoke :: Context -> IO ()
glaFullBlockSmoke ctx = do
  let batch = 1
      n = 10
      heads = 2
      hd = 2
      chunk = 2
      d = heads * hd
      f = 6
      rows = batch * n
      counts = [rows*d, d, d*d, d*d, d*d, d*d, d*d, d, f*d, f*d, d*f]
      total = sum counts
      packed = values total 0.037
      outputBar = values (rows * d) 0.071
      expected = glaFullBlockReference batch n heads hd chunk f packed
      objective candidate = dotList
        (glaFullBlockReference batch n heads hd chunk f candidate)
        (map realToFrac outputBar)
      (x, rmsAtt, wq, wk, wv, wo, walpha, rmsFf, wgate, wup, wdown) =
        unpackGlaBlock rows d f packed
      weights = GlaBlockWeights
        (map realToFrac rmsAtt) (map realToFrac wq) (map realToFrac wk)
        (map realToFrac wv) (map realToFrac wo) (map realToFrac walpha)
        (map realToFrac rmsFf) (map realToFrac wgate) (map realToFrac wup)
        (map realToFrac wdown)
  actual <- glaBlockDecomposed (conformancePieceOps ctx) batch n heads hd chunk f
    (map realToFrac x) weights (map realToFrac outputBar)
  let actualGradient = concat
        [ fullGlaXBar actual
        , fullGlaRmsAttBar actual
        , fullGlaWqBar actual
        , fullGlaWkBar actual
        , fullGlaWvBar actual
        , fullGlaWoBar actual
        , fullGlaWalphaBar actual
        , fullGlaRmsFfBar actual
        , fullGlaWgateBar actual
        , fullGlaWupBar actual
        , fullGlaWdownBar actual
        ]
  compareVector "decomposed full GLA block forward" 2e-4 2e-4 expected
    (map realToFrac (fullGlaOutput actual))
  compareVector "decomposed full GLA block every gradient" 3e-4 3e-4
    (grad objective packed) (map realToFrac actualGradient)
  where
    values :: Int -> Double -> [Double]
    values count frequency =
      [0.22 * cos (fromIntegral (i + 1) * frequency) | i <- [0 .. count - 1]]

glaFullBlockReference
  :: (Floating a, Ord a)
  => Int -> Int -> Int -> Int -> Int -> Int -> [a] -> [a]
glaFullBlockReference batch n heads hd _chunk f packed =
  feedForwardReference d f afterAttention rmsFf wgate wup wdown
  where
    d = heads * hd
    rows = batch * n
    (x, rmsAtt, wq, wk, wv, wo, walpha, rmsFf, wgate, wup, wdown) =
      unpackGlaBlock rows d f packed
    normalized = concatMap (`rmsNormRow` rmsAtt) (chunksOf d x)
    q0 = denseReference d d normalized wq
    k0 = denseReference d d normalized wk
    value = denseReference d d normalized wv
    gate = denseReference d d normalized walpha
    q = concatMap (l2NormalizeHeads heads) (chunksOf d q0)
    k = concatMap (l2NormalizeHeads heads) (chunksOf d k0)
    attendedRaw = glaAttentionReference batch n heads hd q k value gate
    attended
      | glaOutputNorm = concatMap (l2NormalizeHeads heads) (chunksOf d attendedRaw)
      | otherwise = attendedRaw
    afterAttention = zipWith (+) x (denseReference d d attended wo)

unpackGlaBlock
  :: Int -> Int -> Int -> [a]
  -> ([a], [a], [a], [a], [a], [a], [a], [a], [a], [a], [a])
unpackGlaBlock rows d f packed =
  (x, rmsAtt, wq, wk, wv, wo, walpha, rmsFf, wgate, wup, wdown)
  where
    (x, rest1) = splitAt (rows * d) packed
    (rmsAtt, rest2) = splitAt d rest1
    (wq, rest3) = splitAt (d * d) rest2
    (wk, rest4) = splitAt (d * d) rest3
    (wv, rest5) = splitAt (d * d) rest4
    (wo, rest6) = splitAt (d * d) rest5
    (walpha, rest7) = splitAt (d * d) rest6
    (rmsFf, rest8) = splitAt d rest7
    (wgate, rest9) = splitAt (f * d) rest8
    (wup, rest10) = splitAt (f * d) rest9
    (wdown, _) = splitAt (d * f) rest10

oracleSmoke :: Context -> IO ()
oracleSmoke ctx = do
  let vocab = fromIntegral (vocabSize config)
      dim = fromIntegral (modelDim config)
      ff = fromIntegral (ffDim config)
      heads = fromIntegral (headCount config)
      layers = fromIntegral (layerCount config)
      chunk = 2
      paramFloats = map realToFrac parameters
      tokenInts = map fromIntegral tokens :: [Int64]
  count <- oracleParameterCount ctx vocab dim ff layers
  assertExact "oracle parameter count" (fromIntegral (paramCount config)) count
  referenceLogits <- either die pure (fullSequenceLogits config parameters tokens)
  withF32 ctx paramFloats $ \paramsArr ->
    withI64 ctx tokenInts $ \tokensArr -> do
      actualLogits <- oracleLogits ctx (length tokens) vocab dim ff heads layers chunk paramsArr tokensArr
      compareVector "oracle logits" 3e-4 3e-4 (concat referenceLogits) (map realToFrac actualLogits)
  let referenceBatchLoss params = sum
        [ sequenceLossFor sequenceTokens params | sequenceTokens <- batchTokens ]
        / fromIntegral (length batchTokens)
      referenceGradient = grad referenceBatchLoss parameters
      flatBatch = concatMap (map fromIntegral) batchTokens :: [Int64]
  withF32 ctx paramFloats $ \paramsArr ->
    withI64 ctx flatBatch $ \tokensArr -> do
      (loss, gradientValues) <- oracleBatchLossGrad ctx (fromIntegral (length batchTokens))
        (fromIntegral (length tokens)) vocab dim ff heads layers chunk paramsArr tokensArr
      compareScalar "oracle batch loss" 3e-4 3e-4 (referenceBatchLoss parameters) (realToFrac loss)
      compareVector "oracle batch gradient" 2e-3 2e-2 referenceGradient (map realToFrac gradientValues)
      dumpPath <- lookupEnv "GEMM_CONFORMANCE_DUMP"
      case dumpPath of
        Just path ->
          writeFile path (unlines (show loss : map show gradientValues))
        Nothing -> pure ()
      (decomposedLoss, decomposedGradient) <- modelLossGradDecomposed
        (conformancePieceOps ctx) config (fromIntegral chunk)
        (length batchTokens) (length batchTokens)
        paramFloats flatBatch
      compareScalar "decomposed hybrid loss vs fused oracle" 1e-4 1e-4
        (realToFrac loss) (realToFrac decomposedLoss)
      compareVector "decomposed hybrid every gradient vs fused oracle" 1e-4 1e-3
        (map realToFrac gradientValues) (map realToFrac decomposedGradient)
      compareVector "decomposed hybrid every gradient vs Numeric.AD" 2e-3 2e-2
        referenceGradient (map realToFrac decomposedGradient)

sequenceLossFor :: (Floating a, Ord a) => [Int] -> [a] -> a
sequenceLossFor sequenceTokens params = sum losses / fromIntegral (length losses)
  where
    losses =
      [ either error id (nextTokenCEGeneric config params (take index sequenceTokens) (sequenceTokens !! index))
      | index <- [1 .. length sequenceTokens - 1]
      ]

assertExact :: (Eq a, Show a) => String -> a -> a -> IO ()
assertExact label expected actual = do
  unless (expected == actual) (die (label ++ " failed: expected " ++ show expected ++ ", got " ++ show actual))
  putStrLn (label ++ ": exact (" ++ show actual ++ ")")

assertGlaBlock :: (Int, BlockParameters) -> IO ()
assertGlaBlock (i, block) = do
  assertCommonBlock i block
  case blockWalpha block of
    Nothing -> die ("GLA block " ++ show i ++ " is missing walpha")
    Just walpha -> assertShape ("block " ++ show i ++ " walpha") (modelDim config) (modelDim config) walpha

assertSoftmaxBlock :: Int -> BlockParameters -> IO ()
assertSoftmaxBlock i block = do
  assertCommonBlock i block
  case blockWalpha block of
    Nothing -> putStrLn ("block " ++ show i ++ " softmax has no walpha: exact")
    Just _ -> die ("softmax block " ++ show i ++ " unexpectedly has walpha")

assertCommonBlock :: Int -> BlockParameters -> IO ()
assertCommonBlock i block = do
  assertShape (prefix "rms_att") 1 d (blockRmsAtt block)
  assertShape (prefix "wq") d d (blockWq block)
  assertShape (prefix "wk") d d (blockWk block)
  assertShape (prefix "wv") d d (blockWv block)
  assertShape (prefix "wo") d d (blockWo block)
  assertShape (prefix "rms_ff") 1 d (blockRmsFf block)
  assertShape (prefix "wgate") f d (blockWgate block)
  assertShape (prefix "wup") f d (blockWup block)
  assertShape (prefix "wdown") d f (blockWdown block)
  where
    d = modelDim config
    f = ffDim config
    prefix suffix = "block " ++ show i ++ " " ++ suffix

assertShape :: String -> Int -> Int -> MatrixView -> IO ()
assertShape label rows cols view = do
  unless (matrixRows view == rows && matrixCols view == cols) $
    die (label ++ " shape failed: expected " ++ show (rows, cols)
      ++ ", got " ++ show (matrixRows view, matrixCols view))
  putStrLn (label ++ ": shape=" ++ show (rows, cols))

compareScalar :: String -> Double -> Double -> Double -> Double -> IO ()
compareScalar label absolute relative expected actual
  | close absolute relative expected actual = putStrLn (label ++ ": abs=" ++ show (abs (expected - actual)))
  | otherwise = die (label ++ " failed: expected " ++ show expected ++ ", got " ++ show actual)

compareVector :: String -> Double -> Double -> [Double] -> [Double] -> IO ()
compareVector label absolute relative expected actual
  | length expected /= length actual = die (label ++ " failed: length mismatch")
  | otherwise = case failures of
      [] -> putStrLn (label ++ ": elements=" ++ show (length expected) ++ ", max_abs=" ++ show maxAbs)
      (i, x, y) : _ -> die (label ++ " failed at " ++ show i ++ ": expected " ++ show x ++ ", got " ++ show y)
  where
    pairs = zip expected actual
    failures = [(i, x, y) | (i, (x, y)) <- zip [0 :: Int ..] pairs, not (close absolute relative x y)]
    maxAbs = maximum (0 : [abs (x - y) | (x, y) <- pairs])

close :: Double -> Double -> Double -> Double -> Bool
close absolute relative expected actual =
  not (isNaN actual || isInfinite actual) && abs (expected - actual) <= absolute + relative * abs expected
