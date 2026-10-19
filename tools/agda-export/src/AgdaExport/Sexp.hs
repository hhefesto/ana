{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The output syntax (FORMAT.md, "Lexical syntax"): parenthesized lists,
--   bare atoms over [A-Za-z0-9_.-], non-negative decimal integers, and
--   double-quoted strings whose only escapes are \" and \\ (every other
--   character, newline included, is written as itself in UTF-8).
module AgdaExport.Sexp
  ( Sexp (..)
  , atom, str, int, list
  , yesNo, none
  , render, renderPretty
  , countWhere
  ) where

import Control.DeepSeq (NFData)
import Data.ByteString.Builder (Builder, char7, charUtf8, integerDec)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

data Sexp
  = A !Text      -- ^ an atom (the caller keeps it in [A-Za-z0-9_.-])
  | S !Text      -- ^ a string
  | I !Integer   -- ^ a non-negative integer
  | L [Sexp]     -- ^ a list
  deriving (Eq, Show, Generic, NFData)

atom :: Text -> Sexp
atom = A

str :: String -> Sexp
str = S . T.pack

int :: Integral a => a -> Sexp
int = I . toInteger

list :: [Sexp] -> Sexp
list = L

yesNo :: Bool -> Sexp
yesNo b = A (if b then "yes" else "no")

none :: Sexp
none = A "none"

-- | One line, single spaces.
render :: Sexp -> Builder
render = \case
  A t -> textUtf8 t
  S t -> char7 '"' <> T.foldr (\c b -> esc c <> b) mempty t <> char7 '"'
  I n -> integerDec n
  L [] -> char7 '(' <> char7 ')'
  L (x : xs) -> char7 '(' <> render x <> foldr (\y b -> char7 ' ' <> render y <> b) mempty xs <> char7 ')'
  where
    esc '"' = char7 '\\' <> char7 '"'
    esc '\\' = char7 '\\' <> char7 '\\'
    esc c = charUtf8 c

textUtf8 :: Text -> Builder
textUtf8 = T.foldr (\c b -> charUtf8 c <> b) mempty

-- | Indented: a list that fits in the width stays on one line, otherwise its
--   head stays on the opening line and every other element goes on its own
--   line, two spaces deeper.  Still one value, read the same way.
renderPretty :: Int -> Sexp -> Builder
renderPretty width = go 0
  where
    go ind s = case s of
      L (h : xs@(_ : _)) | not (fits (width - ind) s) ->
        -- short leading elements (atoms, names) stay on the opening line
        let leading b (y : ys) | Just left <- budget' b y, not (null ys) = y : leading (left - 1) ys
            leading _ _ = []
            budget' b y = budget 40 y >> budget b y
            short' = leading (60 :: Int) xs
            rest' = drop (length short') xs
        in char7 '(' <> render h <> mconcat [char7 ' ' <> render x | x <- short']
             <> mconcat [ char7 '\n' <> spaces (ind + 2) <> go (ind + 2) x | x <- rest' ]
             <> char7 ')'
      _ -> render s
    spaces n = mconcat (replicate n (char7 ' '))
    -- whether the one-line form is at most n characters (stops early)
    fits n s = case budget n s of
      Just _ -> True
      Nothing -> False
    budget n s
      | n < 0 = Nothing
      | otherwise = case s of
          A t -> sub n (T.length t)
          S t -> sub n (T.length t + 2 + T.count "\"" t + T.count "\\" t)
          I k -> sub n (length (show k))
          L xs -> do
            n' <- sub n (1 + max 0 (length xs - 1) + 1)
            foldlM' budget n' xs
    sub n k = if n - k < 0 then Nothing else Just (n - k)
    foldlM' _ n [] = Just n
    foldlM' f n (x : xs) = f n x >>= \n' -> foldlM' f n' xs

-- | How many sub-expressions satisfy the predicate.
countWhere :: (Sexp -> Bool) -> Sexp -> Int
countWhere p = go
  where
    go s = (if p s then 1 else 0) + case s of
      L xs -> sum (map go xs)
      _ -> 0
