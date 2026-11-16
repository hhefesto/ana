-- FillSim: will R7's filler serve every window? (11-15, before R7's plan-windows)
--
-- bend-windows (ana bend/Windows.bend) fills each window's gap f (CAPACITY - used)
-- best fit: the end of the shortest unused filler document of at least f tokens;
-- a gap no document serves refuses the shard (exit 1). This replays that rule on
-- R6's real gaps (run/v9/R6/parts/part-K.plan, column 1, shard K) against R7's
-- filler as run7.sh builds it: each language's files in order (Bend's K times
-- over), interleaved PER a round without cycling (bend-mix's rule), cut into
-- one equal slice per shard. Token lengths are byte lengths / R, R a language's
-- bytes per token (measured: bend-prepare with weights/code32k.bpe on samples).
--
--   fillsim DIR SHARDS K PER.bend,R.bend PER.haskell,R.haskell ... PER.prose,R.prose
--
-- DIR holds LANG.len (one byte length a line, file order) and plans/part-K.plan.
module Main (main) where

import qualified Data.Map.Strict as M
import Data.List (foldl')
import System.Environment (getArgs)
import Text.Printf (printf)

langs :: [String]
langs = ["bend", "haskell", "lean", "agda", "nix", "prose"]

-- bend-mix's interleave: a round takes up to PER of each stream, in order;
-- a stream that ran dry drops out
interleave :: [(Int, [a])] -> [a]
interleave ss
  | all (null . snd) ss = []
  | otherwise = concatMap (\(p, xs) -> take p xs) ss ++ interleave [(p, drop p xs) | (p, xs) <- ss]

chunks :: Int -> [a] -> [[a]]
chunks _ [] = []
chunks n xs = let (a, b) = splitAt n xs in a : chunks n b

-- best fit over a multiset of lengths: the failures (gaps nothing served)
bestFit :: M.Map Int Int -> [Int] -> Int
bestFit m0 = snd . foldl' step (m0, 0)
  where
    step (m, bad) f
      | f <= 0 = (m, bad)
      | otherwise = case M.lookupGE f m of
          Nothing -> (m, bad + 1)
          Just (k, c) -> (if c == 1 then M.delete k m else M.insert k (c - 1) m, bad)

main :: IO ()
main = do
  dir : shardsS : kS : specS <- getArgs
  let shards = read shardsS :: Int
      k = read kS :: Int
      spec s = let (p, _ : r) = break (== ',') s in (read p :: Int, read r :: Double)
      specs = map spec specS
  lens <- mapM (\l -> map read . lines <$> readFile (dir ++ "/" ++ l ++ ".len")) langs
  -- each file as its token length, by its language's bytes per token
  let tok r b = floor (fromIntegral (b :: Int) / r) :: Int
      streams = [(p, map (tok r) (if l == "bend" then concat (replicate k xs) else xs)) | (l, xs, (p, r)) <- zip3 langs lens specs]
      filler = interleave streams
      total = length filler
      each = (total + shards - 1) `div` shards
      slices = chunks each filler
  printf "filler %d files, %d slices of %d; per language (PER, bytes per token): %s\n" total (length slices) each (unwords specS)
  res <- mapM (\(i, sl) -> do
                  g <- map (read . head . words) . lines <$> readFile (printf "%s/plans/part-%06d.plan" dir (i `mod` 224)) -- R6 had 224 shards; more reuse theirs
                  let m = M.fromListWith (+) [(t, 1) | t <- sl]
                      bad = bestFit m g
                  pure (i, length (filter (> 0) g), length sl, bad))
              (zip [0 :: Int ..] (take shards slices))
  let fails = [x | x@(_, _, _, b) <- res, b > 0]
  mapM_ (\(i, g, n, b) -> printf "shard %d: %d gaps, %d filler files, %d unserved\n" i g n b) fails
  printf "%d of %d shards refused; %d gaps unserved\n" (length fails) (length res) (sum [b | (_, _, _, b) <- res])
