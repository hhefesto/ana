module FormalTransformer.Tokenizer
  ( bosToken
  , eosToken
  , byteVocabSize
  , byteTokenizerIdentity
  , FastBpe
  , Tokenizer (..)
  , loadFastBpe
  , tokenizerIdentityOf
  , tokenizerVocabSize
  , tokenizerVocabularyFromIdentity
  , encodeWith
  , decodeWith
  , validateOrdinaryTokens
  , encodeBytes
  , decodeBytes
  , validateByteTokens
  , pretokenize
  , countWords
  , learnBpeMerges
  , renderBpeArtifact
  ) where

import qualified Crypto.Hash.SHA256 as SHA256
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (isPrefixOf, stripPrefix, tails)
import qualified Data.IntMap.Strict as IntMap
import qualified Data.IntSet as IntSet
import qualified Data.Map.Strict as Map
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import Data.Word (Word8, Word16)
import Numeric (showHex)
import Text.Read (readMaybe)

bosToken, eosToken, byteVocabSize, byteBase, mergeBase :: Int
bosToken = 0
eosToken = 1
byteVocabSize = 258
byteBase = 2
mergeBase = 258

byteTokenizerIdentity :: String
byteTokenizerIdentity = "lossless-byte-v1:bos=0:eos=1:bytes=2..257"

data FastBpe = FastBpe
  { fastBpeVocabSize :: !Int
  , fastBpeMerges :: ![((Int, Int), Int)]
  , fastBpeRanks :: !(Map.Map (Int, Int) Int)
  , fastBpeIdentity :: !String
  }

data Tokenizer = ByteTokenizer | FastBpeTokenizer !FastBpe

loadFastBpe :: FilePath -> IO (Either String FastBpe)
loadFastBpe path = parseFastBpe path . BSC.lines <$> BS.readFile path

parseFastBpe :: FilePath -> [BS.ByteString] -> Either String FastBpe
parseFastBpe path rows = case rows of
  header : mergeRows -> do
    vocab <- case words (BSC.unpack header) of
      ["BPE", value] -> parseInt "vocabulary" value
      _ -> Left ("invalid BPE header in " ++ path ++ " (expected: BPE VOCABULARY)")
    if vocab < mergeBase || vocab > fromIntegral (maxBound :: Word16)
      then Left "BPE vocabulary must be between 258 and 65535"
      else pure ()
    merges <- mapM parseMerge (zip [mergeBase ..] mergeRows)
    if length merges /= vocab - mergeBase
      then Left ("BPE merge count does not match vocabulary: expected "
        ++ show (vocab - mergeBase) ++ ", got " ++ show (length merges))
      else pure ()
    let pairs = map fst merges
    if length pairs /= Map.size (Map.fromList (zip pairs (repeat ())))
      then Left "BPE contains a duplicate merge pair"
      else pure ()
    let digest = hex (SHA256.hash (canonicalBytes vocab merges))
        identity = "fastbpe-word-v1:bos=0:eos=1:bytes=2..257:"
          ++ "pretoken=ascii-space-prefix+lf-boundary:vocab=" ++ show vocab
          ++ ":sha256=" ++ digest
    pure (FastBpe vocab merges (Map.fromList merges) identity)
  [] -> Left ("empty BPE artifact: " ++ path)
  where
    parseMerge (expected, row) = case words (BSC.unpack row) of
      [aText, bText, newText] -> do
        a <- parseInt "left merge operand" aText
        b <- parseInt "right merge operand" bText
        new <- parseInt "merge id" newText
        if new /= expected
          then Left ("BPE merge ids must be contiguous: expected " ++ show expected
            ++ ", got " ++ show new)
          else pure ()
        if a < byteBase || b < byteBase || a >= new || b >= new
          then Left ("BPE merge " ++ show new
            ++ " refers to a reserved, negative, self, or future token")
          else pure ((a, b), new)
      _ -> Left ("invalid BPE merge row: " ++ BSC.unpack row)

    parseInt label value = case readMaybe value of
      Just number -> Right number
      Nothing -> Left ("invalid " ++ label ++ " in BPE artifact: " ++ value)

canonicalBytes :: Int -> [((Int, Int), Int)] -> BS.ByteString
canonicalBytes vocab merges = BSC.pack (unlines
  ( ["fastbpe-word-v1", "vocab " ++ show vocab]
  ++ [unwords [show a, show b, show new] | ((a, b), new) <- merges]
  ))

hex :: BS.ByteString -> String
hex = concatMap twoDigits . BS.unpack
  where
    twoDigits byte = let value = showHex byte "" in replicate (2 - length value) '0' ++ value

tokenizerIdentityOf :: Tokenizer -> String
tokenizerIdentityOf ByteTokenizer = byteTokenizerIdentity
tokenizerIdentityOf (FastBpeTokenizer bpe) = fastBpeIdentity bpe

tokenizerVocabSize :: Tokenizer -> Int
tokenizerVocabSize ByteTokenizer = byteVocabSize
tokenizerVocabSize (FastBpeTokenizer bpe) = fastBpeVocabSize bpe

tokenizerVocabularyFromIdentity :: String -> Maybe Int
tokenizerVocabularyFromIdentity identity
  | identity == byteTokenizerIdentity = Just byteVocabSize
  | not ("fastbpe-word-v1:" `isPrefixOf` identity) = Nothing
  | otherwise = do
      suffix <- listToMaybe [rest | candidate <- tails identity, Just rest <- [stripPrefix ":vocab=" candidate]]
      readMaybe (takeWhile (/= ':') suffix)

encodeWith :: Tokenizer -> BS.ByteString -> [Int]
encodeWith ByteTokenizer bytes = encodeBytes bytes
encodeWith (FastBpeTokenizer bpe) bytes =
  let words' = filter (not . BS.null) (pretokenize bytes)
      unique = Map.fromList [(word, ()) | word <- words']
      memo = Map.mapWithKey (\word _ -> encodeWord (fastBpeRanks bpe) (wordToIds word)) unique
  in concatMap (memo Map.!) words'

decodeWith :: Tokenizer -> [Int] -> Either String BS.ByteString
decodeWith ByteTokenizer tokens = decodeBytes tokens
decodeWith (FastBpeTokenizer bpe) tokens = BS.concat <$> mapM expand tokens
  where
    table = Map.fromList [(new, pair) | (pair, new) <- fastBpeMerges bpe]
    expand token
      | token < byteBase || token >= fastBpeVocabSize bpe =
          Left ("token outside ordinary BPE vocabulary: " ++ show token)
      | token < mergeBase = Right (BS.singleton (fromIntegral (token - byteBase)))
      | otherwise = case Map.lookup token table of
          Nothing -> Left ("undefined BPE merge token: " ++ show token)
          Just (a, b) -> (<>) <$> expand a <*> expand b

validateOrdinaryTokens :: Tokenizer -> [Int] -> Either String ()
validateOrdinaryTokens tokenizer tokens
  | all (\token -> token >= byteBase && token < tokenizerVocabSize tokenizer) tokens = Right ()
  | otherwise = Left ("ordinary tokens must lie in [2," ++ show (tokenizerVocabSize tokenizer - 1) ++ "]")

encodeBytes :: BS.ByteString -> [Int]
encodeBytes = map ((+ byteBase) . fromIntegral) . BS.unpack

decodeBytes :: [Int] -> Either String BS.ByteString
decodeBytes tokens = do
  validateByteTokens tokens
  pure (BS.pack (map (fromIntegral . subtract byteBase) tokens))

validateByteTokens :: [Int] -> Either String ()
validateByteTokens = validateOrdinaryTokens ByteTokenizer

pretokenize :: BS.ByteString -> [BS.ByteString]
pretokenize bytes
  | BS.null bytes = []
  | byte == 10 = BS.take 1 bytes : pretokenize (BS.drop 1 bytes)
  | byte == 32 =
      let (word, remaining) = BS.span (\value -> value /= 32 && value /= 10) (BS.drop 1 bytes)
      in BS.cons 32 word : pretokenize remaining
  | otherwise =
      let (word, remaining) = BS.span (\value -> value /= 32 && value /= 10) bytes
      in word : pretokenize remaining
  where
    byte = BS.head bytes

wordToIds :: BS.ByteString -> [Int]
wordToIds = map (\byte -> byteBase + fromIntegral (byte :: Word8)) . BS.unpack

encodeWord :: Map.Map (Int, Int) Int -> [Int] -> [Int]
encodeWord ranks = go
  where
    go tokens = case bestAdjacent tokens of
      Nothing -> tokens
      Just (pair, new) -> go (applyMerge pair new tokens)
    bestAdjacent tokens = case
      [ (rank, pair)
      | pair <- zip tokens (drop 1 tokens)
      , Just rank <- [Map.lookup pair ranks]
      ] of
        [] -> Nothing
        candidates -> let (rank, pair) = minimum candidates in Just (pair, rank)

applyMerge :: (Int, Int) -> Int -> [Int] -> [Int]
applyMerge (a, b) new = go
  where
    go (x : y : remaining)
      | x == a && y == b = new : go remaining
      | otherwise = x : go (y : remaining)
    go values = values

-- Accumulate word frequencies using the encoder's own `pretokenize`, so the
-- trainer and the encoder agree on what a word is by construction.  That
-- agreement is the correctness-critical part: an external trainer with its own
-- pretokenization would produce merges the encoder can never apply, and the
-- failure would be silent.
countWords :: Map.Map BS.ByteString Int -> BS.ByteString -> Map.Map BS.ByteString Int
countWords acc text =
  foldl' bump acc (filter (not . BS.null) (pretokenize text))
  where bump m word = Map.insertWith (+) word 1 m

-- Learn BPE merges from a word-frequency table.
--
-- BPE trains over word *types*, not the corpus, so cost is set by the number of
-- distinct words rather than by corpus size -- a 45 GB corpus and a 5 GB one
-- differ only in the counting pass.
--
-- Merges are emitted lowest-id first, which is the order `encodeWord` applies
-- them: it repeatedly takes the lowest-ranked applicable pair, so merge id is
-- rank.  Pair counts are maintained incrementally against a `Set (count, pair)`
-- index, because rescanning every pair to find the maximum would be O(pairs)
-- per merge and there are tens of thousands of merges.
learnBpeMerges :: Int -> Map.Map BS.ByteString Int -> Either String [((Int, Int), Int)]
learnBpeMerges vocab frequencies
  | vocab <= mergeBase = Left "BPE vocabulary must exceed 258 (the byte tokens)"
  | vocab > fromIntegral (maxBound :: Word16) = Left "BPE vocabulary must not exceed 65535"
  | Map.null frequencies = Left "no words to learn from"
  | otherwise = Right (reverse (loop mergeBase state0 []))
  where
    indexed = zip [0 ..] (Map.toList frequencies)
    symbols0 = IntMap.fromList [(i, wordToIds word) | (i, (word, _)) <- indexed]
    weights = IntMap.fromList [(i, n) | (i, (_, n)) <- indexed]

    state0 = foldl' addWord (Map.empty, Set.empty, Map.empty, symbols0) indexed
      where
        addWord acc (i, (word, n)) =
          insertPairs i n (adjacent (wordToIds word)) acc

    -- Emitting stops early if the corpus runs out of merges before the target
    -- vocabulary; `renderBpeArtifact` derives the header from what was actually
    -- learned, so the artifact stays self-consistent either way.
    loop next state emitted
      | next >= vocab = emitted
      | otherwise =
          let (_, byCount, occurs, _) = state
          in case Set.lookupMax byCount of
               Nothing -> emitted
               Just (_, pair) ->
                 let touched = IntSet.toList (Map.findWithDefault IntSet.empty pair occurs)
                     state' = foldl' (rewrite pair next) state touched
                 in loop (next + 1) state' ((pair, next) : emitted)

    -- Replace one pair throughout a word: drop the word's old pairs, apply the
    -- merge, then re-add.  Removing and re-adding the whole word is O(length)
    -- and keeps the three indices exactly consistent, which a targeted patch
    -- around the merge site is easy to get subtly wrong.
    rewrite pair new (counts, byCount, occurs, symbols) i =
      let old = IntMap.findWithDefault [] i symbols
          n = IntMap.findWithDefault 0 i weights
          stripped = removePairs i n (adjacent old) (counts, byCount, occurs, symbols)
          merged = applyMerge pair new old
          (c', b', o', _) = insertPairs i n (adjacent merged) stripped
      in (c', b', o', IntMap.insert i merged symbols)

    insertPairs i n pairs acc = foldl' step acc pairs
      where step st p = adjustPair p n (IntSet.insert i) st

    removePairs i n pairs acc = foldl' step acc pairs
      where step st p = adjustPair p (negate n) (IntSet.delete i) st

    adjustPair p delta touch (counts, byCount, occurs, symbols) =
      let before = Map.findWithDefault 0 p counts
          after = before + delta
          removed = if before > 0 then Set.delete (before, p) byCount else byCount
          byCount' = if after > 0 then Set.insert (after, p) removed else removed
          counts' = if after > 0 then Map.insert p after counts else Map.delete p counts
          occurs' = Map.alter (prune . touch . maybe IntSet.empty id) p occurs
      in (counts', byCount', occurs', symbols)
      where prune s = if IntSet.null s then Nothing else Just s

adjacent :: [Int] -> [(Int, Int)]
adjacent tokens = zip tokens (drop 1 tokens)

-- Render the artifact `parseFastBpe` reads back: a header naming the total
-- vocabulary, then one `left right id` row per merge with contiguous ids.
renderBpeArtifact :: [((Int, Int), Int)] -> BS.ByteString
renderBpeArtifact merges = BSC.pack (unlines
  (("BPE " ++ show (mergeBase + length merges))
    : [unwords [show a, show b, show new] | ((a, b), new) <- merges]))
