module Dense
  ( denseForward
  , densePullback
  ) where

import Blas
import Buffer

-- Canonical transformer projection: rows of activations times rows of a
-- row-major weight matrix, i.e. Y[rows,out] = X[rows,in] * W[out,in]^T.
denseForward :: Blas -> MatrixView -> MatrixView -> MatrixView -> IO ()
denseForward blas x weights output =
  blasGemm blas NoTrans Trans 1 x weights 0 output

densePullback
  :: Blas
  -> MatrixView
  -> MatrixView
  -> MatrixView
  -> MatrixView
  -> MatrixView
  -> IO ()
densePullback blas x weights outputBar xBar weightsBar =
  blasGemmPullback blas NoTrans Trans 1 x weights outputBar xBar weightsBar
