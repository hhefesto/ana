module Main (main) where

import Blas
import Buffer
import Control.Exception (IOException, try)
import Control.Monad (forM_, unless)
import Data.List (transpose)
import Foreign.C.Types (CInt)
import Foreign.Storable (peekElemOff)

type Matrix = [[Float]]

main :: IO ()
main = do
  testViewChecks
  testGemm "NN" NoTrans NoTrans left right
  testGemm "NT" NoTrans Trans left (transpose right)
  testGemm "TN" Trans NoTrans (transpose left) right
  testBatchedSharedB
  testBatchedSharedA
  testZeroInnerDimension
  testCallChecks
  putStrLn "BLAS self-tests passed"
  where
    left = [[1, -2, 3], [4, 0.5, -1]]
    right = [[2, 1], [-1, 3], [0.25, -2]]

testViewChecks :: IO ()
testViewChecks = do
  buffer <- newBuffer 8
  expectLeft "negative offset" (matrixView buffer (-1) 1 1 1)
  expectLeft "short leading dimension" (matrixView buffer 0 2 3 2)
  expectLeft "view overrun" (matrixView buffer 1 2 3 5)
  view <- checked (matrixView buffer 0 2 2 3)
  expectLeft "negative batch stride" (batchView view 2 (-1))
  expectLeft "batch overrun" (batchView view 3 3)

testGemm :: String -> Transpose -> Transpose -> Matrix -> Matrix -> IO ()
testGemm name transA transB physicalA physicalB = do
  (aBuffer, a) <- paddedView physicalA 1
  (bBuffer, b) <- paddedView physicalB 2
  let logicalA = applyTranspose transA physicalA
      logicalB = applyTranspose transB physicalB
      m = length logicalA
      n = matrixColumnCount logicalB
      initialC = matrix m n [fromIntegral (i - 3) / 4 | i <- [0 .. m * n - 1]]
      expected = addMatrix (scale 0.75 (matmul logicalA logicalB)) (scale (-0.25) initialC)
  (cBuffer, c) <- paddedView initialC 3
  blasGemm openBlas transA transB 0.75 a b (-0.25) c
  actual <- readView c
  assertMatrix name expected actual
  -- Keep explicit references alive through the FFI call and readback.
  unless (sum (map bufferLength [aBuffer, bBuffer, cBuffer]) > 0) $
    fail "unexpected empty GEMM buffers"

testBatchedSharedB :: IO ()
testBatchedSharedB = do
  let aMatrices = [left, [[-1, 2, 0], [3, -2, 1]]]
      sharedB = [[1, 2], [0, -1], [3, 0.5]]
  (aBuffer, a) <- packedBatch aMatrices
  (_, b) <- paddedView sharedB 0
  cBuffer <- newBuffer 8
  c <- checked (matrixView cBuffer 0 2 2 2)
  as <- checked (batchView a 2 6)
  bs <- checked (batchView b 2 0)
  cs <- checked (batchView c 2 4)
  blasGemmBatched openBlas NoTrans NoTrans 1 as bs 0 cs
  actual <- readBatch cs
  assertBatches "batched shared B" (map (`matmul` sharedB) aMatrices) actual
  unless (bufferLength aBuffer == 12) (fail "packed A batch has wrong size")
  where
    left = [[1, 0, 2], [-1, 3, 1]]

testBatchedSharedA :: IO ()
testBatchedSharedA = do
  let sharedA = [[1, -1], [2, 0.5]]
      bMatrices = [[[2], [3]], [[-1], [4]]]
  (_, a) <- paddedView sharedA 0
  (_, b) <- packedBatch bMatrices
  cBuffer <- newBuffer 4
  c <- checked (matrixView cBuffer 0 2 1 1)
  as <- checked (batchView a 2 0)
  bs <- checked (batchView b 2 2)
  cs <- checked (batchView c 2 2)
  blasGemmBatched openBlas NoTrans NoTrans 1 as bs 0 cs
  actual <- readBatch cs
  assertBatches "batched shared A" (map (matmul sharedA) bMatrices) actual

testZeroInnerDimension :: IO ()
testZeroInnerDimension = do
  empty <- newBuffer 0
  cBuffer <- bufferFromList [1, -2, 3, 4]
  a <- checked (matrixView empty 0 2 0 0)
  b <- checked (matrixView empty 0 0 2 2)
  c <- checked (matrixView cBuffer 0 2 2 2)
  blasGemm openBlas NoTrans NoTrans 7 a b (-0.5) c
  actual <- readView c
  assertMatrix "zero inner dimension" [[-0.5, 1], [-1.5, -2]] actual

testCallChecks :: IO ()
testCallChecks = do
  one <- bufferFromList [1]
  ordinary <- checked (matrixView one 0 1 1 1)
  two <- bufferFromList [1, 2]
  wrongOutput <- checked (matrixView two 0 1 2 2)
  expectFailure "dimension mismatch" $
    blasGemm openBlas NoTrans NoTrans 1 ordinary ordinary 0 wrongOutput
  expectFailure "TT rejection" $
    blasGemm openBlas Trans Trans 1 ordinary ordinary 0 ordinary
  shared <- checked (batchView ordinary 2 0)
  singleton <- checked (batchView ordinary 1 0)
  expectFailure "batch count mismatch" $
    blasGemmBatched openBlas NoTrans NoTrans 1 shared singleton 0 singleton
  expectFailure "zero output stride" $
    blasGemmBatched openBlas NoTrans NoTrans 1 shared shared 0 shared
  let tooLarge = toInteger (maxBound :: CInt) + 1
  if tooLarge <= toInteger (maxBound :: Int)
    then do
      hugeLd <- checked (matrixView one 0 1 1 (fromInteger tooLarge))
      expectFailure "CInt leading dimension" $
        blasGemm openBlas NoTrans NoTrans 1 hugeLd ordinary 0 ordinary
      empty <- newBuffer 0
      hugeA <- checked (matrixView empty 0 0 (fromInteger tooLarge) (fromInteger tooLarge))
      hugeB <- checked (matrixView empty 0 (fromInteger tooLarge) 0 0)
      emptyC <- checked (matrixView empty 0 0 0 0)
      expectFailure "CInt matrix dimension" $
        blasGemm openBlas NoTrans NoTrans 1 hugeA hugeB 0 emptyC
      hugeBatch <- checked (batchView ordinary (fromInteger tooLarge) 0)
      expectFailure "CInt batch count" $
        blasGemmBatched openBlas NoTrans NoTrans 1 hugeBatch hugeBatch 0 hugeBatch
    else pure ()

paddedView :: Matrix -> Int -> IO (Buffer, MatrixView)
paddedView rows padding = case rows of
  [] -> fail "cannot create a padded view from an empty matrix"
  firstRow : _ -> do
    let cols = length firstRow
        leadingDim = cols + padding
        values = concatMap (\row -> row ++ replicate padding 12345) rows
    unless (all ((== cols) . length) rows) (fail "ragged test matrix")
    buffer <- bufferFromList values
    view <- checked (matrixView buffer 0 (length rows) cols leadingDim)
    pure (buffer, view)

packedBatch :: [Matrix] -> IO (Buffer, MatrixView)
packedBatch matrices = case matrices of
  [] -> fail "cannot create an empty packed test batch"
  firstMatrix : _ -> case firstMatrix of
    [] -> fail "cannot pack matrices with no rows"
    firstRow : _ -> do
      let rows = length firstMatrix
          cols = length firstRow
      unless (all (\m -> length m == rows && all ((== cols) . length) m) matrices) $
        fail "inconsistent packed test batch shapes"
      buffer <- bufferFromList (concatMap concat matrices)
      view <- checked (matrixView buffer 0 rows cols cols)
      pure (buffer, view)

readView :: MatrixView -> IO Matrix
readView view = withMatrixPtr view $ \ptr ->
  mapM (\row -> mapM (peekElemOff ptr . (row * matrixLeadingDim view +))
          [0 .. matrixCols view - 1])
    [0 .. matrixRows view - 1]

readBatch :: BatchView -> IO [Matrix]
readBatch batch = mapM (\i -> checked (batchMatrixAt batch i) >>= readView)
  [0 .. batchCount batch - 1]

applyTranspose :: Transpose -> Matrix -> Matrix
applyTranspose NoTrans = id
applyTranspose Trans = transpose

matmul :: Matrix -> Matrix -> Matrix
matmul a b =
  [[sum (zipWith (*) row col) | col <- transpose b] | row <- a]

matrix :: Int -> Int -> [Float] -> Matrix
matrix rows cols values =
  [take cols (drop (row * cols) values) | row <- [0 .. rows - 1]]

matrixColumnCount :: Matrix -> Int
matrixColumnCount [] = 0
matrixColumnCount (row : _) = length row

scale :: Float -> Matrix -> Matrix
scale factor = map (map (factor *))

addMatrix :: Matrix -> Matrix -> Matrix
addMatrix = zipWith (zipWith (+))

assertBatches :: String -> [Matrix] -> [Matrix] -> IO ()
assertBatches label expected actual =
  forM_ (zip3 [0 :: Int ..] expected actual) $ \(i, want, got) ->
    assertMatrix (label ++ " batch " ++ show i) want got

assertMatrix :: String -> Matrix -> Matrix -> IO ()
assertMatrix label expected actual = do
  unless (length expected == length actual && map length expected == map length actual) $
    fail (label ++ ": shape mismatch")
  forM_ (zip3 [0 :: Int ..] (concat expected) (concat actual)) $ \(i, want, got) ->
    unless (abs (want - got) <= 1e-5 * max 1 (abs want)) $
      fail (label ++ ": element " ++ show i ++ ": expected " ++ show want ++ ", got " ++ show got)

checked :: Either String a -> IO a
checked = either fail pure

expectLeft :: String -> Either String a -> IO ()
expectLeft label result = case result of
  Left _ -> pure ()
  Right _ -> fail (label ++ ": expected metadata validation failure")

expectFailure :: String -> IO () -> IO ()
expectFailure label action = do
  result <- try action :: IO (Either IOException ())
  case result of
    Left _ -> pure ()
    Right _ -> fail (label ++ ": expected BLAS validation failure")
