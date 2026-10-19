-- | Agda's internal syntax as S-expressions (FORMAT.md, "Terms" onwards).
--   A pure, total transcription: every constructor of Term, Elim, Sort,
--   Level, Pattern and CompiledClauses has its own form.  Variables carry
--   their de Bruijn index and the name of the binder they point at, which
--   the encoder tracks through every binder it passes ('Ctx').
module AgdaExport.Encode
  ( Ctx
  , qnameS, moduleNameS, nameIdS
  , argInfoS, hidingA, relevanceA, quantityA
  , termS, typS, sortS, levelS, elimS, domS
  , telescopeS, telNames
  , patternS, namedPatternS
  , compiledS
  , litS
  , rangeS, rangeLines
  , unboundHint
  , noparamsMark
  ) where

import qualified Data.Map as Map
import Data.Char (ord)
import qualified Data.Text as T
import Numeric (showFFloat)

import qualified Agda.Syntax.Abstract.Name as AN
import Agda.Syntax.Common
import Agda.Syntax.Common.Pretty (prettyShow)
import Agda.Syntax.Internal
import qualified Agda.Syntax.Internal as I
import Agda.Syntax.Literal
import Agda.Syntax.Position
import Agda.Syntax.TopLevelModuleName ()
import Agda.TypeChecking.CompiledClause
import qualified Agda.Utils.Maybe.Strict as Strict
import Agda.Utils.FileName (filePath)

import AgdaExport.Sexp

-- | The names of the variables in scope, innermost (de Bruijn 0) first.
type Ctx = [ArgName]

-- | The hint written for an index the encoder has no binder for (it does
--   not happen in a well-scoped termS; the summary counts it).
unboundHint :: T.Text
unboundHint = "?unbound"

-- | The name of the Dummy term the exporter wraps around a clause body it
--   could not make explicit, so that the case-tree leaf it becomes is
--   written as noparams too.
noparamsMark :: String
noparamsMark = "agda-export:noparams"

hint :: Ctx -> Int -> Sexp
hint cx i = case drop i cx of
  (x : _) -> str x
  [] -> S unboundHint

------------------------------------------------------------------------
-- Names

-- | @(q "Printed.Qualified.Name" W H)@: Agda's rendering of the name and
--   its NameId (a counter and the hash of the top-levelS module that made
--   it), which tells apart names that print the same.
qnameS :: QName -> Sexp
qnameS q = L (A "q" : str (prettyShow q) : nameIdS (qnameName q))

nameIdS :: Name -> [Sexp]
nameIdS n = case AN.nameId n of
  NameId w (ModuleNameHash h) -> [int w, int h]

moduleNameS :: ModuleName -> Sexp
moduleNameS = str . prettyShow

------------------------------------------------------------------------
-- Argument information

-- | The three atoms every argument, binder and domain carries.
argInfoS :: ArgInfo -> [Sexp]
argInfoS ai = [hidingA (getHiding ai), relevanceA (getRelevance ai), quantityA (getQuantity ai)]

hidingA :: Hiding -> Sexp
hidingA = \case
  NotHidden -> A "visible"
  Hidden -> A "hidden"
  Instance{} -> A "instance"

relevanceA :: Relevance -> Sexp
relevanceA = \case
  Relevant{} -> A "relevant"
  ShapeIrrelevant{} -> A "shape-irrelevant"
  Irrelevant{} -> A "irrelevant"

quantityA :: Quantity -> Sexp
quantityA = \case
  Quantity0{} -> A "q0"
  Quantity1{} -> A "q1"
  Quantityω{} -> A "w"

------------------------------------------------------------------------
-- Terms

termS :: Ctx -> Term -> Sexp
termS cx = \case
  Var i es -> L (A "var" : int i : hint cx i : map (elimS cx) es)
  Lam ai b -> L (A "lam" : argInfoS ai ++ [absS cx termS b])
  Lit l -> L [A "lit", litS l]
  Def q es -> L (A "def" : qnameS q : map (elimS cx) es)
  Con ch ci es -> L (A "con" : qnameS (conName ch) : conOrigin ci : map (elimS cx) es)
  Pi d b -> L [A "pi", domS cx d, absS cx typS b]
  Sort s -> L [A "sort", sortS cx s]
  Level l -> L [A "level", levelS cx l]
  MetaV m es -> L (A "meta" : metaIdS m ++ map (elimS cx) es)
  DontCare v -> L [A "dontcare", termS cx v]
  Dummy s [Apply (Arg _ v)] | s == noparamsMark -> L [A "noparams", termS cx v]
  Dummy s es -> L (A "dummy" : str s : map (elimS cx) es)

absS :: Ctx -> (Ctx -> a -> Sexp) -> Abs a -> Sexp
absS cx f = \case
  Abs x b -> L [A "abs", str x, f (x : cx) b]
  NoAbs x b -> L [A "noabs", str x, f cx b]

elimS :: Ctx -> Elim -> Sexp
elimS cx = \case
  Apply (Arg ai v) -> L (A "apply" : argInfoS ai ++ [termS cx v])
  Proj o q -> L [A "proj", projOrigin o, qnameS q]
  IApply x y r -> L [A "iapply", termS cx x, termS cx y, termS cx r]

typS :: Ctx -> Type -> Sexp
typS cx (El s t) = L [A "el", sortS cx s, termS cx t]

-- | @(domS HIDING RELEVANCE QUANTITY NAME TYPE)@, NAME the argument's name
--   for named application (@{x = ...}@) or none.
domS :: Ctx -> Dom Type -> Sexp
domS cx d = L (A "dom" : argInfoS (domInfo d) ++ [domNameS d, typS cx (unDom d)])

domNameS :: Dom' t e -> Sexp
domNameS d = maybe none (str . rangedThing . woThing) (domName d)

sortS :: Ctx -> Sort -> Sexp
sortS cx = \case
  Univ u l -> L [univA u, levelS cx l]
  Inf u n -> L [A "inf", univA u, int n]
  SizeUniv -> L [A "sizeuniv"]
  LockUniv -> L [A "lockuniv"]
  LevelUniv -> L [A "leveluniv"]
  IntervalUniv -> L [A "intervaluniv"]
  PiSort d s1 s2 ->
    L [A "pisort", L (A "dom" : argInfoS (domInfo d) ++ [domNameS d, termS cx (unDom d)]), sortS cx s1, absS cx sortS s2]
  FunSort s1 s2 -> L [A "funsort", sortS cx s1, sortS cx s2]
  UnivSort s -> L [A "univsort", sortS cx s]
  MetaS m es -> L (A "metas" : metaIdS m ++ map (elimS cx) es)
  DefS q es -> L (A "defs" : qnameS q : map (elimS cx) es)
  DummyS s -> L [A "dummys", str s]
  where
    univA = \case
      UProp -> A "prop"
      UType -> A "set"
      USSet -> A "sset"

levelS :: Ctx -> Level -> Sexp
levelS cx (Max n as) = L (A "max" : int n : [L [A "plus", int k, termS cx a] | Plus k a <- as])

litS :: Literal -> Sexp
litS = \case
  LitNat n -> L [A "nat", int n]
  LitWord64 n -> L [A "word64", int n]
  LitFloat d -> L [A "float", str (showFFloat Nothing d "")]
  LitString t -> L [A "string", S t]
  LitChar c -> L [A "char", int (ord c)]
  LitQName q -> L [A "qname", qnameS q]
  LitMeta m x -> L (A "meta" : str (prettyShow m) : metaIdS x)

metaIdS :: MetaId -> [Sexp]
metaIdS (MetaId w (ModuleNameHash h)) = [int w, int h]

conOrigin :: ConOrigin -> Sexp
conOrigin = \case
  ConOSystem -> A "system"
  ConOCon -> A "con"
  ConORec -> A "rec"
  ConOSplit -> A "split"

projOrigin :: ProjOrigin -> Sexp
projOrigin = \case
  ProjPrefix -> A "prefix"
  ProjPostfix -> A "postfix"
  ProjSystem -> A "system"

------------------------------------------------------------------------
-- Telescopes

-- | The bindings of a telescopeS, each @(b NAME HIDING RELEVANCE QUANTITY
--   DOMNAME TYPE)@ with its type in the scope of the earlier ones; and the
--   context after all of them.
telescopeS :: Ctx -> Telescope -> ([Sexp], Ctx)
telescopeS cx = \case
  EmptyTel -> ([], cx)
  ExtendTel d b ->
    let x = absName b
        (rest, cx') = telescopeS (x : cx) (unAbs b)
    in (L (A "b" : str x : argInfoS (domInfo d) ++ [domNameS d, typS cx (unDom d)]) : rest, cx')

-- | The context a telescopeS binds (innermost first).
telNames :: Telescope -> Ctx
telNames = snd . telescopeS []

------------------------------------------------------------------------
-- Patterns (the de Bruijn indices of patternS variables count in the
-- clause telescopeS, as do the terms inside dot patterns)

namedPatternS :: Ctx -> NamedArg DeBruijnPattern -> Sexp
namedPatternS cx (Arg ai (Named nm p)) =
  L (A "p" : argInfoS ai ++ [maybe none (str . rangedThing . woThing) nm, patternS cx p])

patternS :: Ctx -> DeBruijnPattern -> Sexp
patternS cx = \case
  VarP i x -> L [A "pvar", str (dbPatVarName x), int (dbPatVarIndex x), porig (i)]
  DotP i v -> L [A "pdot", porig (i), termS cx v]
  ConP ch ci ps ->
    L ( A "pcon" : qnameS (conName ch) : porig ((conPInfo ci))
      : L [A "record", yesNo (conPRecord ci)]
      : L [A "lazy", yesNo (conPLazy ci)]
      : L [A "fallthrough", yesNo (conPFallThrough ci)]
      : L (A "type" : maybe [none] (\(Arg ai t) -> argInfoS ai ++ [typS cx t]) (conPType ci))
      : map (namedPatternS cx) ps )
  LitP i l -> L [A "plit", porig (i), litS l]
  ProjP o q -> L [A "pproj", projOrigin o, qnameS q]
  IApplyP i x y v -> L [A "piapply", porig (i), termS cx x, termS cx y, str (dbPatVarName v), int (dbPatVarIndex v)]
  DefP i q ps -> L (A "pdef" : porig (i) : qnameS q : map (namedPatternS cx) ps)

porig :: PatternInfo -> Sexp
porig i = case I.patOrigin i of
  PatOSystem -> A "system"
  PatOSplit -> A "split"
  PatOSplitArg{} -> A "split-arg"
  PatOVar{} -> A "var"
  PatODot -> A "dot"
  PatOWild -> A "wild"
  PatOCon -> A "con"
  PatORec -> A "rec"
  PatOLit -> A "lit"
  PatOAbsurd -> A "absurd"

------------------------------------------------------------------------
-- Case trees

-- | A compiledS case tree.  @Case n@ matches the n-th (from 0) of the
--   arguments so far; a constructor branch of arity k puts k new arguments
--   in that place; a copattern branch (copattern yes) matches the next
--   projection.  The body of @done@ is in the scope of its vars (the last
--   of them is de Bruijn 0).
compiledS :: CompiledClauses -> Sexp
compiledS = \case
  Case n bs -> L (A "case" : argInfoS (argInfoS' n) ++ [int (unArg n), branches bs])
  Done xs v -> L [A "done", vars xs, termS (reverse (map unArg xs)) v]
  Fail xs -> L [A "fail", vars xs]
  where
    argInfoS' (Arg ai _) = ai
    vars xs = L (A "vars" : [L (A "x" : argInfoS ai ++ [str x]) | Arg ai x <- xs])
    branches (Branches cop cons eta lits ca ft lazy) =
      L [ A "branches"
        , L [A "copattern", yesNo cop]
        , L (A "cons" : [L [A "br", qnameS c, int a, compiledS t] | (c, WithArity a t) <- Map.toList cons])
        , L (A "eta" : maybe [none] (\(ch, WithArity a t) -> [qnameS (conName ch), int a, compiledS t]) eta)
        , L (A "lits" : [L [A "lbr", litS l, compiledS t] | (l, t) <- Map.toList lits])
        , L [A "catchall", maybe none compiledS ca]
        , L [A "fallthrough", maybe none yesNo ft]
        , L [A "lazy", yesNo lazy]
        ]

------------------------------------------------------------------------
-- Source positions

-- | @(range FILE LINE COL LINE COL)@ (lines and columns from 1, the end
--   exclusive as Agda keeps it) or @(range none)@.
rangeS :: Range -> Sexp
rangeS r = case (rangeFile r, rStart' r, rEnd' r) of
  (Strict.Just f, Just s, Just e) ->
    L [A "range", str (filePath (rangeFilePath f)), int (posLine s), int (posCol s), int (posLine e), int (posCol e)]
  (Strict.Nothing, Just s, Just e) ->
    L [A "range", none, int (posLine s), int (posCol s), int (posLine e), int (posCol e)]
  _ -> L [A "range", none]

-- | The file and the first and last line of a range.
rangeLines :: Range -> Maybe (Maybe FilePath, Integer, Integer)
rangeLines r = case (rStart' r, rEnd' r) of
  (Just s, Just e) ->
    Just ( case rangeFile r of
             Strict.Just f -> Just (filePath (rangeFilePath f))
             Strict.Nothing -> Nothing
         , toInteger (posLine s), toInteger (posLine e) )
  _ -> Nothing
