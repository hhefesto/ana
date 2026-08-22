-- | Concatenating short documents so they survive windowing.
--
-- The trainer cuts each document into non-overlapping windows of exactly
-- `contextSize` tokens ("FormalTransformer.Data".'fullWindows') and discards
-- the remainder, so a document shorter than one window contributes nothing at
-- all and every document donates its tail to the floor.  That is survivable at
-- context 256 and ruinous at 1024.  Measured over a uniform sample of 388,027
-- documents (every 25th across all 9.7M of run/mixed-corpus.jsonl), as the
-- percentage of bytes that land inside a full window:
--
-- >                    ctx 256   ctx 512   ctx 1024
-- >   unpacked           82.9%     69.8%      51.9%
-- >   packed 128 KB      99.6%     99.2%      98.3%
--
-- At context 1024, 82.4% of documents yield no window at all unpacked, and
-- packing is the difference between ~3.6B and ~7B usable tokens on this
-- corpus.  Beware measuring this on the head of a file: Wikipedia is
-- article-ordered with a stub tail, so the first documents run 2.2x larger
-- than the corpus mean and a head sample understates the loss by half.
--
-- The residue after packing is the per-document tail, which is why a bigger
-- target is always slightly better, and why chasing the last percent is not
-- worth making documents so large that the 90/10 split (a hash of document
-- position, "FormalTransformer.Data") becomes coarse.  128 KB clears 98% while
-- keeping twice as many documents as 256 KB.
--
-- This operates on the NUL-delimited id/text stream that @prepare-bpe-stdin@
-- already consumes, so @jq@ keeps doing the JSON and the packer needs no JSON
-- parser of its own.
module FormalTransformer.Pack
  ( PackConfig(..)
  , defaultPackConfig
  , PackState
  , freshPack
  , packStep
  , packFlush
  , packedCount
  , groupOf
  , nulDocuments
  , packAll
  ) where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Text.Printf (printf)

data PackConfig = PackConfig
  { packTarget :: !Int
    -- ^ Emit once the accumulated text reaches this many bytes.  A source
    -- document is never split, so a single document larger than the target is
    -- emitted alone.
  , packPrefix :: String
    -- ^ Document id prefix; ids are @prefix-00000000@ and unique by
    -- construction, which 'FormalTransformer.Artifact' requires -- a duplicate
    -- id rejects the whole shard.
  , packSeparator :: BS.ByteString
    -- ^ Placed between packed pieces.  A blank line is what a language model
    -- sees between documents everywhere else.
  , packGrouped :: !Bool
    -- ^ Pack only within a group, where a document's group is the part of its
    -- id before the first @/@.  Used for code, so a window never straddles two
    -- unrelated repositories.  Groups must arrive contiguous; a group that
    -- reappears later simply starts a new packed document, which costs a
    -- little packing efficiency and nothing in correctness.
  } deriving (Eq, Show)

defaultPackConfig :: PackConfig
defaultPackConfig = PackConfig
  { packTarget = 131072
  , packPrefix = "pack"
  , packSeparator = BSC.pack "\n\n"
  , packGrouped = False
  }

-- | Held pieces are kept reversed; nothing larger than one pack is ever
-- retained, which is what lets a 35 GB corpus stream through in constant
-- memory.
data PackState = PackState
  { heldPieces :: [BS.ByteString]
  , heldBytes :: !Int
  , heldGroup :: Maybe BS.ByteString
  , emitted :: !Int
  } deriving (Eq, Show)

freshPack :: PackState
freshPack = PackState [] 0 Nothing 0

-- | Packed documents emitted so far.
packedCount :: PackState -> Int
packedCount = emitted

-- | A document's group: its id up to the first @/@.  Ids without one are all
-- one group, which is why 'packGrouped' is off unless the caller asks for it.
groupOf :: BS.ByteString -> BS.ByteString
groupOf = BSC.takeWhile (/= '/')

-- | Feed one source document.  Returns the new state and any packed documents
-- this one completed.  A group change can close the held pack /and/ the new
-- document can fill one by itself, so the result is a list rather than a
-- 'Maybe': collapsing it to one emission silently drops a document.
packStep :: PackConfig -> PackState -> (BS.ByteString, BS.ByteString)
  -> (PackState, [(String, BS.ByteString)])
packStep cfg state (documentId, text)
  -- An empty document would contribute a bare separator and nothing else.
  | BS.null text = (state, [])
  -- A group change closes the current pack even when it is nearly empty:
  -- mixing repositories inside one window is exactly what grouping prevents.
  | boundary =
      let (flushed, closed) = packFlush cfg state
          (state', out) = packStep cfg flushed (documentId, text)
      in (state', maybe out (: out) closed)
  | full = let (state', out) = packFlush cfg added in (state', maybe [] pure out)
  | otherwise = (added, [])
  where
    group = groupOf documentId
    started = null (heldPieces state)
    boundary = packGrouped cfg && not started && heldGroup state /= Just group
    -- The separator only exists /between/ pieces, so the first piece does not
    -- pay for one; counting it there would fire the target a separator early.
    added = state
      { heldPieces = text : heldPieces state
      , heldBytes = heldBytes state + BS.length text
          + (if started then 0 else BS.length (packSeparator cfg))
      , heldGroup = if started then Just group else heldGroup state
      }
    full = heldBytes added >= packTarget cfg

-- | Emit whatever is held.  Called at end of input and whenever a pack fills.
packFlush :: PackConfig -> PackState -> (PackState, Maybe (String, BS.ByteString))
packFlush cfg state
  | null (heldPieces state) = (state, Nothing)
  | otherwise =
      ( state { heldPieces = [], heldBytes = 0, heldGroup = Nothing
              , emitted = emitted state + 1 }
      , Just (printf "%s-%08d" (packPrefix cfg) (emitted state)
             , BS.intercalate (packSeparator cfg) (reverse (heldPieces state))) )

-- | Incremental NUL parser: as many complete id/text pairs as @bytes@ holds,
-- plus the unconsumed remainder.  Splitting the input at any chunk boundary
-- must not change the result, which is the property the tests pin.
nulDocuments :: BS.ByteString -> ([(BS.ByteString, BS.ByteString)], BS.ByteString)
nulDocuments = go []
  where
    go acc bytes = case BS.elemIndex 0 bytes of
      Nothing -> (reverse acc, bytes)
      Just idEnd ->
        let rest = BS.drop (idEnd + 1) bytes
        in case BS.elemIndex 0 rest of
          Nothing -> (reverse acc, bytes)
          Just textEnd ->
            go ((BS.take idEnd bytes, BS.take textEnd rest) : acc)
               (BS.drop (textEnd + 1) rest)

-- | Pack a complete list of documents.  The streaming driver produces exactly
-- this, which is what makes the pure function a real test of the IO path.
packAll :: PackConfig -> [(BS.ByteString, BS.ByteString)] -> [(String, BS.ByteString)]
packAll cfg = finish . foldl step (freshPack, [])
  where
    step (state, out) document =
      let (state', packed) = packStep cfg state document
      in (state', reverse packed ++ out)
    finish (state, out) = case packFlush cfg state of
      (_, Nothing) -> reverse out
      (_, Just packed) -> reverse (packed : out)
