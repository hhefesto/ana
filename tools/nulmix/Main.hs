{-# LANGUAGE BangPatterns #-}
-- nulmix: PlanWindows.bend's rounds (nm.q.go, the mixes done directly) at disk speed.
--
--   nulmix OUT IDS TOTAL NAME:PER:HELD:PATH,PATH,... ...
--
-- Each round takes PER documents of every language in the order given; a language
-- that runs dry leaves the rounds.  PATHs are read in turn, and from the third on an
-- id gets filler-union's #c<pass> (two paths a pass: files-hi, files-lo).  HELD, if
-- given, is a NUL file whose ids (up to a #) are left out.  OUT gets id NUL text NUL,
-- IDS the ids a line each, TOTAL the number of documents; stdout gets what the Bend
-- road says.
--
-- Why not Bend: a byte is a list cell there (S.Rd, S.emit), 0.8 MB/s on one core, and
-- a plan's 14 GB filler took 5 hours of its 14 (2026-11-05).  nm.q.go stays as the
-- meaning and the fallback; `cmp` of the two roads on R5b's mix.nul (6.4 GB) and
-- filler.nul (14.2 GB) is in HANDOFF.md.
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as LC
import qualified Data.Set as Set
import Control.Monad (when)
import System.Environment (getArgs)
import System.Exit (die)
import System.IO

data Lang = Lang
  { name :: String
  , per :: !Int
  , held :: !(Set.Set B.ByteString)
  , at :: !Int -- paths read before this one
  , cur :: L.ByteString
  , more :: [FilePath]
  , docs :: !Int
  , bytes :: !Int
  }

-- the field up to its NUL, and what follows it; Nothing at the end of the stream
field :: String -> L.ByteString -> IO (Maybe (L.ByteString, L.ByteString))
field what s
  | L.null s = pure Nothing
  | otherwise = case L.elemIndex 0 s of
      Nothing -> die ("nulmix: " ++ what ++ ": the stream ends inside a field (no final NUL)")
      Just i -> let (f, r) = L.splitAt i s in pure (Just (f, L.drop 1 r))

-- the ids of a NUL file of pairs, each up to its first #
heldIds :: FilePath -> IO (Set.Set B.ByteString)
heldIds "" = pure Set.empty
heldIds p = L.readFile p >>= go Set.empty
  where
    go !s t = do
      m <- field p t
      case m of
        Nothing -> pure s
        Just (i, r) -> do
          m2 <- field p r
          let s' = Set.insert (B.takeWhile (/= 35) (L.toStrict i)) s
          case m2 of
            Nothing -> pure s'
            Just (_, r2) -> go s' r2

-- a language's turn: Left when it has run dry, Right when it took its PER
turn :: Handle -> Handle -> Lang -> IO (Either Lang Lang)
turn o ids l0 = go (per l0) l0
  where
    go 0 l = pure (Right l)
    go left l = do
      m <- field (name l) (cur l)
      case m of
        Nothing -> case more l of
          [] -> pure (Left l)
          p : ps -> do
            s <- L.readFile p
            go left l {cur = s, more = ps, at = at l + 1}
        Just (i, r1) -> do
          m2 <- field (name l) r1
          case m2 of
            Nothing -> die ("plan-windows: a NUL stream of " ++ name l ++ " ends after an id")
            Just (t, r2)
              | Set.member (L.toStrict i) (held l) -> go left l {cur = r2}
              | otherwise -> do
                  let idc
                        | at l < 2 = i
                        | otherwise = i <> LC.pack ("#c" ++ show (at l `div` 2))
                  L.hPut o idc
                  L.hPut o nul
                  L.hPut o t
                  L.hPut o nul
                  L.hPut ids idc
                  hPutChar ids '\n'
                  go (left - 1 :: Int) l {cur = r2, docs = docs l + 1, bytes = bytes l + fromIntegral (L.length t)}
    nul = L.singleton 0

line :: Lang -> String
line l = "  " ++ name l ++ ": " ++ show (docs l) ++ " documents, " ++ show (bytes l) ++ " bytes of text"

-- the languages this round has yet to take; those it has taken, newest first
rounds :: Handle -> Handle -> [Lang] -> [Lang] -> Int -> IO Int
rounds _ _ [] [] !total = pure total
rounds o ids [] nx !total = rounds o ids (reverse nx) [] total
rounds o ids (l : now) nx !total = do
  r <- turn o ids l
  case r of
    Left dry -> putStrLn (line dry) >> rounds o ids now nx (total + docs dry)
    Right l' -> rounds o ids now (l' : nx) total

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : r) -> a : splitOn c r

open :: String -> IO Lang
open spec = case splitOn ':' spec of
  [n, p, h, ps] -> do
    let paths = splitOn ',' ps
    when (null ps) (die ("nulmix: no paths in " ++ spec))
    hs <- heldIds h
    when (h /= "") (putStrLn (n ++ ": " ++ show (Set.size hs) ++ " holdout files left out"))
    s <- L.readFile (head paths)
    pure Lang {name = n, per = read p, held = hs, at = 0, cur = s, more = tail paths, docs = 0, bytes = 0}
  _ -> die ("nulmix: NAME:PER:HELD:PATH,...: " ++ spec)

out :: FilePath -> IO Handle
out p = do
  h <- openBinaryFile p WriteMode
  hSetBuffering h (BlockBuffering (Just 1048576))
  pure h

main :: IO ()
main = do
  args <- getArgs
  case args of
    op : ip : tp : specs@(_ : _) -> do
      hSetBuffering stdout LineBuffering
      ls <- mapM open specs
      o <- out op
      ids <- out ip
      total <- rounds o ids ls [] 0
      hClose o
      hClose ids
      C.writeFile tp (C.pack (show total ++ "\n"))
    _ -> die "usage: nulmix OUT IDS TOTAL NAME:PER:HELD:PATH,PATH,... ..."
