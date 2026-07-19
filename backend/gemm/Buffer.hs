module Buffer
  ( Buffer
  , MatrixView
  , BatchView
  , newBuffer
  , bufferFromList
  , bufferLength
  , readBuffer
  , writeBuffer
  , fillBuffer
  , bufferToList
  , matrixView
  , matrixRows
  , matrixCols
  , matrixLeadingDim
  , batchView
  , batchCount
  , batchStride
  , batchMatrix
  , batchMatrixAt
  , withMatrixPtr
  ) where

import Control.Monad (forM, forM_)
import Foreign.Marshal.Array (advancePtr)
import Foreign.Ptr (Ptr)
import qualified Data.Vector.Storable.Mutable as SM

-- Storable vectors are contiguous, foreign-allocated, and pinned. Keeping the
-- mutable vector opaque also keeps its ForeignPtr alive for every pointer use.
newtype Buffer = Buffer (SM.IOVector Float)

data MatrixView = MatrixView
  { matrixBuffer :: !Buffer
  , matrixOffset :: !Int
  , matrixRows :: !Int
  , matrixCols :: !Int
  , matrixLeadingDim :: !Int
  }

data BatchView = BatchView
  { batchBase :: !MatrixView
  , batchCount :: !Int
  , batchStride :: !Int
  }

newBuffer :: Int -> IO Buffer
newBuffer n
  | n < 0 = ioError (userError "buffer length must be non-negative")
  | otherwise = Buffer <$> SM.new n

bufferFromList :: [Float] -> IO Buffer
bufferFromList values = do
  buffer <- newBuffer (length values)
  forM_ (zip [0 ..] values) $ uncurry (writeBuffer buffer)
  pure buffer

bufferLength :: Buffer -> Int
bufferLength (Buffer values) = SM.length values

readBuffer :: Buffer -> Int -> IO Float
readBuffer (Buffer values) i = SM.read values i

writeBuffer :: Buffer -> Int -> Float -> IO ()
writeBuffer (Buffer values) i = SM.write values i

fillBuffer :: Buffer -> Float -> IO ()
fillBuffer (Buffer values) = SM.set values

bufferToList :: Buffer -> IO [Float]
bufferToList buffer = forM [0 .. bufferLength buffer - 1] (readBuffer buffer)

matrixView :: Buffer -> Int -> Int -> Int -> Int -> Either String MatrixView
matrixView buffer offset rows cols leadingDim = do
  validateView buffer offset rows cols leadingDim
  pure (MatrixView buffer offset rows cols leadingDim)

batchView :: MatrixView -> Int -> Int -> Either String BatchView
batchView view count stride
  | count < 0 = Left "batch count must be non-negative"
  | stride < 0 = Left "batch stride must be non-negative"
  | otherwise = do
      let lastOffset
            | count == 0 = toInteger (matrixOffset view)
            | otherwise = toInteger (matrixOffset view) + toInteger (count - 1) * toInteger stride
      if lastOffset > toInteger (maxBound :: Int)
        then Left "batched matrix offset exceeds Int range"
        else validateView (matrixBuffer view) (fromInteger lastOffset)
               (matrixRows view) (matrixCols view) (matrixLeadingDim view)
      pure (BatchView view count stride)

batchMatrixAt :: BatchView -> Int -> Either String MatrixView
batchMatrixAt batch i
  | i < 0 || i >= batchCount batch = Left "batch index out of bounds"
  | otherwise =
      let view = batchBase batch
          offset = matrixOffset view + i * batchStride batch
      in matrixView (matrixBuffer view) offset (matrixRows view)
           (matrixCols view) (matrixLeadingDim view)

batchMatrix :: BatchView -> MatrixView
batchMatrix = batchBase

withMatrixPtr :: MatrixView -> (Ptr Float -> IO a) -> IO a
withMatrixPtr view action =
  case matrixBuffer view of
    Buffer values -> SM.unsafeWith values $ \ptr ->
      action (ptr `advancePtr` matrixOffset view)

validateView :: Buffer -> Int -> Int -> Int -> Int -> Either String ()
validateView buffer offset rows cols leadingDim
  | offset < 0 = Left "matrix offset must be non-negative"
  | rows < 0 = Left "matrix rows must be non-negative"
  | cols < 0 = Left "matrix columns must be non-negative"
  | leadingDim < cols = Left "matrix leading dimension is smaller than its column count"
  | end > toInteger (bufferLength buffer) = Left "matrix view exceeds its buffer"
  | otherwise = Right ()
  where
    end
      | rows == 0 || cols == 0 = toInteger offset
      | otherwise = toInteger offset
          + toInteger (rows - 1) * toInteger leadingDim
          + toInteger cols
