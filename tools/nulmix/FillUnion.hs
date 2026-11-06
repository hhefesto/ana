{-# LANGUAGE BangPatterns #-}
-- fillunion: a plan's filler, `bend-corpus-v2 filler-union` and `keyed-order nul` in one go.
--
--   fillunion OUT SALT held=RESULTS.nul DIR...
--
-- Every DIR's files-hi.nul, then every DIR's files-lo.nul: each id once, the first
-- version wins; a file holding a held-out unit's declaration and body byte for byte is
-- left out and named, and does not take its id.  OUT holds the records in order of
-- sha256(SALT NUL id).  What it prints is what the two Bend steps print.
--
-- Why not Bend: filler-union splits every file into lines of list cells; R5's 43,528
-- files (500 MB) took 5.7 hours on one core (2026-11-04), and R5c's filler is more of
-- them, at the end of the night.  The meaning stays bend/CorpusV2/Steps.bend's
-- (st.fu.*) and Keyed.bend's; a cmp of the two roads on R5's filler is in HANDOFF.md.
module Main (main) where

import qualified Crypto.Hash.SHA256 as SHA
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import Data.List (foldl', isPrefixOf, sortOn)
import qualified Data.Set as Set
import Control.Monad (foldM)
import System.Directory (doesFileExist)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO

-- NUL-framed fields; a file that does not end with a NUL is refused
fields :: FilePath -> B.ByteString -> IO [B.ByteString]
fields p s
  | B.null s = pure []
  | B.last s /= 0 = die ("fillunion: " ++ p ++ ": the stream ends inside a field (no final NUL)")
  | otherwise = pure (B.split 0 (B.init s))

pairs :: [B.ByteString] -> [(B.ByteString, B.ByteString)]
pairs (i : t : r) = (i, t) : pairs r
pairs _ = []

-- a held-out unit's first line and the text to find (fields 6 and 7 of its record,
-- fewer than 40 bytes: nothing to find)
data Held = Held {firsts :: !(Set.Set B.ByteString), keys :: [B.ByteString]}

held :: FilePath -> IO Held
held "" = pure (Held Set.empty [])
held p = do
  fs <- B.readFile p >>= fields p
  let ks = [k | (_, t) <- pairs fs, let k = key t, B.length k >= 40]
      key t = case drop 6 (B.split 30 t) of
        a : b : _ -> a <> b
        [a] -> a
        [] -> B.empty
  pure (Held (Set.fromList (map (C.takeWhile (/= '\n')) ks)) ks)

leak :: Held -> B.ByteString -> Bool
leak h t =
  any (`Set.member` firsts h) (C.split '\n' t) && any (`B.isInfixOf` t) (keys h)

data St = St {seen :: !(Set.Set B.ByteString), out :: [(B.ByteString, B.ByteString, B.ByteString)]}

-- one file of one DIR; the kept records are copied out of the file's buffer
file :: B.ByteString -> Held -> St -> FilePath -> FilePath -> IO St
file salt h st0 d f = do
  let p = d ++ "/" ++ f
  ex <- doesFileExist p
  fs <- if ex then B.readFile p >>= fields p else pure []
  let go (!st, !k) (i, t)
        | Set.member i (seen st) = pure (st, k)
        | leak h t = C.putStrLn (C.pack "held: " <> i) >> pure (st, k)
        | otherwise =
            let i' = B.copy i
             in pure
                  ( St
                      (Set.insert i' (seen st))
                      ((SHA.hash (salt <> B.singleton 0 <> i'), i', B.copy t) : out st)
                  , k + 1 :: Int
                  )
  (st1, k) <- foldM go (st0, 0) (pairs fs)
  putStrLn (d ++ " " ++ f ++ " " ++ show k ++ " files")
  pure st1

main :: IO ()
main = do
  args <- getArgs
  case args of
    o : salt : rest@(_ : _) -> do
      hSetBuffering stdout LineBuffering
      let hs = [drop 5 a | a <- rest, "held=" `isPrefixOf` a]
          ds = [a | a <- rest, not ("held=" `isPrefixOf` a)]
          s = C.pack salt
      h <- held (case hs of p : _ -> p; [] -> "")
      st <-
        foldM
          (\st f -> foldM (\st' d -> file s h st' d f) st ds)
          (St Set.empty [])
          ["files-hi.nul", "files-lo.nul"]
      let rs = sortOn (\(k, _, _) -> k) (out st)
          nul = B.singleton 0
      w <- openBinaryFile (o ++ ".tmp") WriteMode
      hSetBuffering w (BlockBuffering (Just 1048576))
      mapM_ (\(_, i, t) -> B.hPut w i >> B.hPut w nul >> B.hPut w t >> B.hPut w nul) rs
      hClose w
      let n = foldl' (\c _ -> c + 1 :: Int) 0 rs
      putStrLn ("keyed-order: " ++ show n ++ " of " ++ show n ++ " records into " ++ o ++ ".tmp")
    _ -> die "usage: fillunion OUT SALT [held=RESULTS.nul] DIR..."
