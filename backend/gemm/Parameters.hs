module Parameters
  ( Parameters (..)
  , BlockParameters (..)
  , parameterViews
  ) where

import Buffer
import Control.Monad (forM)
import FormalTransformer.Config
import FormalTransformer.Layout

data Parameters = Parameters
  { paramsEmbedding :: !MatrixView
  , paramsBlocks :: ![BlockParameters]
  , paramsFinalRms :: !MatrixView
  }

data BlockParameters = BlockParameters
  { blockRmsAtt :: !MatrixView
  , blockWq :: !MatrixView
  , blockWk :: !MatrixView
  , blockWv :: !MatrixView
  , blockWo :: !MatrixView
  , blockWalpha :: !(Maybe MatrixView)
  , blockRmsFf :: !MatrixView
  , blockWgate :: !MatrixView
  , blockWup :: !MatrixView
  , blockWdown :: !MatrixView
  }

parameterViews :: Config -> Buffer -> Either String Parameters
parameterViews cfg buffer = do
  layout <- namedLayout cfg
  embedding <- matrix "embedding" (vocabSize cfg) (modelDim cfg) layout
  blocks <- forM [0 .. layerCount cfg - 1] (block layout)
  finalRms <- vector "final_rms" (modelDim cfg) layout
  pure (Parameters embedding blocks finalRms)
  where
    d = modelDim cfg
    f = ffDim cfg

    block layout i = do
      rmsAtt <- vector prefixRmsAtt d layout
      wq <- matrix (prefix "wq") d d layout
      wk <- matrix (prefix "wk") d d layout
      wv <- matrix (prefix "wv") d d layout
      wo <- matrix (prefix "wo") d d layout
      walpha <- if isSoftmaxLayer cfg i
        then pure Nothing
        else Just <$> matrix (prefix "walpha") d d layout
      rmsFf <- vector (prefix "rms_ff") d layout
      wgate <- matrix (prefix "wgate") f d layout
      wup <- matrix (prefix "wup") f d layout
      wdown <- matrix (prefix "wdown") d f layout
      pure (BlockParameters rmsAtt wq wk wv wo walpha rmsFf wgate wup wdown)
      where
        prefix suffix = "blocks." ++ show i ++ "." ++ suffix
        prefixRmsAtt = prefix "rms_att"

    vector name len layout = do
      slice <- lookupSlice name layout
      if sliceLength slice /= len
        then Left ("layout slice has wrong length for " ++ name)
        else matrixView buffer (sliceOffset slice) 1 len len

    matrix name rows cols layout = do
      slice <- lookupSlice name layout
      if sliceLength slice /= rows * cols
        then Left ("layout slice has wrong matrix shape for " ++ name)
        else matrixView buffer (sliceOffset slice) rows cols cols

lookupSlice :: String -> [Slice] -> Either String Slice
lookupSlice name layout = case filter ((== name) . sliceName) layout of
  [slice] -> Right slice
  [] -> Left ("missing layout slice: " ++ name)
  _ -> Left ("duplicate layout slice: " ++ name)
