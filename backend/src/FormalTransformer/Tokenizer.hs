module FormalTransformer.Tokenizer
  ( bosToken
  , eosToken
  , byteVocabSize
  , byteTokenizerIdentity
  , encodeBytes
  , decodeBytes
  , validateByteTokens
  ) where

import qualified Data.ByteString as BS

bosToken, eosToken, byteVocabSize :: Int
bosToken = 0
eosToken = 1
byteVocabSize = 258

byteTokenizerIdentity :: String
byteTokenizerIdentity = "lossless-byte-v1:bos=0:eos=1:bytes=2..257"

encodeBytes :: BS.ByteString -> [Int]
encodeBytes = map ((+ 2) . fromIntegral) . BS.unpack

decodeBytes :: [Int] -> Either String BS.ByteString
decodeBytes tokens = do
  validateByteTokens tokens
  pure (BS.pack (map (fromIntegral . subtract 2) tokens))

validateByteTokens :: [Int] -> Either String ()
validateByteTokens tokens
  | any (\token -> token < 2 || token > 257) tokens =
      Left "byte-token sequence must contain only ordinary tokens in 2..257"
  | otherwise = Right ()
