module FormalTransformer.AD
  ( lossGradient
  ) where

import FormalTransformer.Config
import FormalTransformer.Model (nextTokenCEGeneric)
import Numeric.AD (grad)

lossGradient :: Config -> [Double] -> [Int] -> Int -> Either String [Double]
lossGradient c params prefix target = do
  _ <- nextTokenCEGeneric c params prefix target
  pure (grad objective params)
  where
    objective ps = case nextTokenCEGeneric c ps prefix target of
      Left message -> error ("lossGradient: " ++ message)
      Right loss -> loss
