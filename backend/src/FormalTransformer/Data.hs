{-# LANGUAGE DeriveGeneric #-}

module FormalTransformer.Data
  ( Document (..)
  , Example (..)
  , Split (..)
  , splitDocuments
  , splitDocumentsFrom
  , windowDocument
  , prepareSplit
  , trainerSplitSeed
  , trainerValidationFraction
  , fullWindows
  , trainerWindowSplit
  , trainerWindowSplitFrom
  ) where

import Data.Bits (shiftR, xor)
import Data.Binary (Binary)
import Data.Word (Word64)
import GHC.Generics (Generic)

import FormalTransformer.Tokenizer (bosToken, eosToken)

data Document = Document
  { documentId :: !String
  , documentTokens :: ![Int]
  } deriving (Eq, Show, Generic)

instance Binary Document

data Example = Example
  { exampleDocumentId :: !String
  , exampleInput :: ![Int]
  , exampleTarget :: !Int
  } deriving (Eq, Show)

data Split a = Split
  { training :: ![a]
  , validation :: ![a]
  } deriving (Eq, Show)

splitDocuments :: Word64 -> Double -> [Document] -> Either String (Split Document)
splitDocuments = splitDocumentsFrom 0

splitDocumentsFrom :: Word64 -> Word64 -> Double -> [Document] -> Either String (Split Document)
splitDocumentsFrom offset seed validationFraction documents
  | validationFraction < 0 || validationFraction > 1 = Left "validation fraction must be in [0,1]"
  | otherwise = Right (Split train valid)
  where
    threshold = floor (validationFraction * 1000000) :: Word64
    tagged = zipWith (\i doc ->
      (mix (seed + offset + fromIntegral i) `mod` 1000000 < threshold, doc))
      [0 :: Int ..] documents
    valid = [doc | (True, doc) <- tagged]
    train = [doc | (False, doc) <- tagged]

windowDocument :: Int -> Document -> Either String [Example]
windowDocument context doc
  | context < 2 = Left "context must be at least 2"
  | any (< 2) (documentTokens doc) = Left "documents may only contain ordinary tokens (>=2); BOS/EOS are inserted"
  | otherwise = Right
      [ Example (documentId doc) (take context (drop start stream)) (stream !! target)
      | target <- [1 .. length stream - 1]
      , let start = max 0 (target - context)
      ]
  where stream = 0 : documentTokens doc ++ [1]

prepareSplit :: Word64 -> Double -> Int -> [Document] -> Either String (Split Example)
prepareSplit seed fraction context documents = do
  docs <- splitDocuments seed fraction documents
  train <- concat <$> mapM (windowDocument context) (training docs)
  valid <- concat <$> mapM (windowDocument context) (validation docs)
  pure (Split train valid)

-- The trainer's document split is part of run semantics: the bigram gate
-- and the GPU host must select identical train and validation windows.
trainerSplitSeed :: Word64
trainerSplitSeed = 0x46544f50454e434c

trainerValidationFraction :: Double
trainerValidationFraction = 0.1

-- Full fixed-width windows over BOS : document ++ [EOS], non-overlapping
-- (stride = width): every token is a next-token prediction target at most
-- once, so consuming all windows consumes all training material exactly
-- once.  Documents shorter than the width contribute no windows.
fullWindows :: Int -> Document -> [[Int]]
fullWindows width doc =
  [take width (drop offset stream) | offset <- [0, width .. length stream - width]]
  where stream = bosToken : documentTokens doc ++ [eosToken]

trainerWindowSplit :: Int -> [Document] -> Either String (Split [Int])
trainerWindowSplit = trainerWindowSplitFrom 0

trainerWindowSplitFrom :: Word64 -> Int -> [Document] -> Either String (Split [Int])
trainerWindowSplitFrom offset width documents = do
  docs <- splitDocumentsFrom offset trainerSplitSeed trainerValidationFraction documents
  let convert = concatMap (fullWindows width)
      result = Split (convert (training docs)) (convert (validation docs))
  if null (training result)
    then Left "training split has no full context sequences"
    else Right result

mix :: Word64 -> Word64
mix x0 = x3 `xor` (x3 `shiftR` 31)
  where
    x1 = (x0 `xor` (x0 `shiftR` 30)) * 0xbf58476d1ce4e5b9
    x2 = (x1 `xor` (x1 `shiftR` 27)) * 0x94d049bb133111eb
    x3 = x2
