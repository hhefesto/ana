{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | One module's export: the header and one @(def ...)@ per definition of
--   its signature (all of them, in the order compilers see them), written
--   to OUT/<Module.Name>.sexp.  FORMAT.md describes every field.
module AgdaExport.Module
  ( Opts (..)
  , defaultOpts
  , ModStats (..)
  , exportModule
  , skippedStats
  , statsSexp
  , logLine
  , moduleFile
  ) where

import Control.DeepSeq (NFData, force)
import qualified Control.Exception as E
import Control.Monad (forM, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import Data.Char (isSpace)
import Data.IORef
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import GHC.Clock (getMonotonicTime)
import GHC.Generics (Generic)
import Numeric (showFFloat)
import System.Directory (createDirectoryIfMissing, renameFile)
import System.FilePath ((</>))
import System.Environment (lookupEnv)
import System.IO

import Agda.Compiler.Common (curIF, sortDefs)
import Agda.Interaction.FindFile (findFile)
import Agda.Interaction.Library.Base (OptionsPragma (..))
import Agda.Syntax.Common
import Agda.Syntax.Common.Pretty (prettyShow)
import Agda.Syntax.Internal
import Agda.Syntax.Position (Range)
import Agda.TypeChecking.CompiledClause (CompiledClauses, CompiledClauses' (..))
import Agda.TypeChecking.CompiledClause.Compile (RunRecordPatternTranslation (..), compileClauses')
import Agda.TypeChecking.Coverage.SplitTree (SplitTree, SplitTree' (..))
import Agda.Utils.Size (size)
import Agda.TypeChecking.Monad
import Agda.Utils.FileName (filePath)
import Agda.Utils.Impossible (Impossible)
import Agda.Utils.Lens ((^.))
import qualified Agda.Utils.SmallSet as SmallSet

import AgdaExport.Encode
import AgdaExport.Explicit
import AgdaExport.Sexp

------------------------------------------------------------------------
-- Options and statistics

data Opts = Opts
  { optDir :: Maybe FilePath
    -- ^ --export-dir: where the .sexp files go (the backend is on when set)
  , optPretty :: Bool
    -- ^ --export-pretty: indented output
  , optExplicit :: Bool
    -- ^ off with --export-stored-only: no parameter reconstruction
  , optSkipExisting :: Bool
    -- ^ --export-skip-existing: keep a module whose .sexp is already there
  , optCopyTypes :: Bool
    -- ^ --export-copy-types: write a module application's copies in full
    --   (by default a copy function keeps only its case tree)
  }
  deriving (Generic, NFData)

defaultOpts :: Opts
defaultOpts = Opts Nothing False True False False

data ModStats = ModStats
  { msModule :: Text
  , msSkipped :: Bool
  , msDefs :: Int
  , msBytes :: Int
  , msSeconds :: Double
  , msKinds :: Map.Map Text Int
  , msExplicit :: Int      -- ^ terms, types, telescopes given their parameters
  , msStored :: Int        -- ^ those left as stored (noparams)
  , msTreesExplicit :: Int -- ^ case trees recompiled from the explicit clauses
  , msTreesStored :: Int   -- ^ case trees left as stored
  , msResidualProj :: Int  -- ^ proj eliminations left outside noparams
  , msUnbound :: Int       -- ^ variables with no binder in scope (0 expected)
  , msReasons :: Map.Map Text Int -- ^ why terms stayed stored
  }

skippedStats :: Text -> ModStats
skippedStats m = ModStats m True 0 0 0 Map.empty 0 0 0 0 0 0 Map.empty

moduleFile :: FilePath -> TopLevelModuleName -> FilePath
moduleFile dir m = dir </> (prettyShow m ++ ".sexp")

------------------------------------------------------------------------
-- Logging (UTC-6, the project's clock)

logLine :: String -> IO ()
logLine msg = do
  now <- getCurrentTime
  let stamp = formatTime defaultTimeLocale "%F %T" (addUTCTime (-6 * 3600) now)
  hPutStrLn stderr ("[" ++ stamp ++ " UTC-6] agda-export: " ++ msg)
  hFlush stderr

------------------------------------------------------------------------
-- Running reconstruction safely

data Counters = Counters
  { cExplicit :: !Int
  , cStored :: !Int
  , cTreesExplicit :: !Int
  , cTreesStored :: !Int
  , cReasons :: !(Map.Map Text Int)
  }

data Env = Env
  { envOpts :: Opts
  , envCounters :: IORef Counters
  , envDef :: String   -- ^ the definition being encoded (for AGDA_EXPORT_DEBUG)
  , envDebug :: Bool   -- ^ AGDA_EXPORT_DEBUG set: log every term left stored
  , envReasonPrefix :: Text
    -- ^ "no-compilation: " for the cubical helpers Agda generates (transp,
    --   hcomp; their terms do not re-check outside cubical Agda)
  , envCompact :: Bool
    -- ^ the definition is a copy written compactly: no clauses
  }

-- | Run a TCM action in a scratch copy of the state and return its forced
--   result; any synchronous exception (a type error, an internal
--   __IMPOSSIBLE__, a failed lazy match) becomes a short reason.
tryTCM :: NFData a => TCM a -> TCM (Either E.SomeException a)
tryTCM m = TCM $ \r e -> do
  s <- readIORef r
  (Right <$> (E.evaluate . force =<< unTCM (localTCState m) r e)) `E.catch` \(ex :: E.SomeException) ->
    case E.fromException ex of
      Just (async :: E.SomeAsyncException) -> E.throwIO async
      Nothing -> do
        writeIORef r s
        return (Left ex)

-- | Why a reconstruction failed: a short class (counted in the index), or
--   with the detail flag a longer message (AGDA_EXPORT_DEBUG).
reason :: Bool -> E.SomeException -> Text
reason detail ex
  | Just (err :: TCErr) <- E.fromException ex = T.pack $ case err of
      TypeError _ _ cl
        | detail -> "type error: " ++ take 600 (unwords (words (show (clValue cl))))
        | otherwise -> "type error: " ++ unwords (take 2 (words (show (clValue cl))))
      _ -> "error: " ++ firstLine (show err)
  | Just (imp :: Impossible) <- E.fromException ex =
      T.pack $ "impossible: " ++ firstLine (concat [l | l <- lines (show imp), "Location" `isPrefixOf` dropWhile isSpace l])
  | otherwise = T.pack ("exception: " ++ firstLine (show ex))
  where
    firstLine = take 120 . takeWhile (/= '\n') . dropWhile isSpace

-- | The explicit form if it can be made, else @(noparams STORED)@.
attempt :: Env -> String -> TCM Sexp -> Sexp -> TCM Sexp
attempt env what act stored = fst <$> attemptWith env what ((\s -> (s, ())) <$> act) stored

-- | Like 'attempt', also returning the explicit value the encoding came from.
attemptWith :: NFData a => Env -> String -> TCM (Sexp, a) -> Sexp -> TCM (Sexp, Maybe a)
attemptWith env what act stored
  | not (optExplicit (envOpts env)) = return (L [A "noparams", stored], Nothing)
  | otherwise = do
      res <- tryTCM (inTopContext act)
      case res of
        Right (s, a) -> do
          bump env (\c -> c { cExplicit = cExplicit c + 1 })
          return (s, Just a)
        Left ex -> do
          noteStored env { envDef = envDef env ++ " [" ++ what ++ "]" } ex
          return (L [A "noparams", stored], Nothing)

bump :: Env -> (Counters -> Counters) -> TCM ()
bump env f = liftIO $ modifyIORef' (envCounters env) f

-- | Count a term left stored, and why (logged under AGDA_EXPORT_DEBUG).
noteStored :: Env -> E.SomeException -> TCM ()
noteStored env ex = noteStoredWhy env (reason False ex) (reason True ex)

noteStoredWhy :: Env -> Text -> Text -> TCM ()
noteStoredWhy env why detail = do
  bump env (\c -> c { cStored = cStored c + 1, cReasons = Map.insertWith (+) (envReasonPrefix env <> why) 1 (cReasons c) })
  when (envDebug env) $ liftIO $ logLine ("stored: " ++ envDef env ++ ": " ++ T.unpack detail)

------------------------------------------------------------------------
-- A module

exportModule :: Opts -> TopLevelModuleName -> TCM ModStats
exportModule opts tlm = do
  let dir = maybe "." id (optDir opts)
      out = moduleFile dir tlm
      tmp = out ++ ".part"
  t0 <- liftIO getMonotonicTime
  i <- curIF
  let defs = sortDefs (iSignature i ^. sigDefinitions)
  cref <- liftIO $ newIORef (Counters 0 0 0 0 Map.empty)
  debug <- liftIO $ isJust <$> lookupEnv "AGDA_EXPORT_DEBUG"
  let env = Env opts cref "" debug "" False
      emit s = if optPretty opts then renderPretty 100 s else render s
  header <- moduleHeader i (length defs)
  liftIO $ createDirectoryIfMissing True dir
  h <- liftIO $ openBinaryFile tmp WriteMode
  bytes0 <- liftIO $ writeOne h (emit header)
  results <- forM defs $ \(_, d) -> do
    (kind, s) <- encodeDef env d
    n <- liftIO $ writeOne h (emit s)
    return (kind, n, residualProj s, countWhere (== S unboundHint) s)
  liftIO $ hClose h
  liftIO $ renameFile tmp out
  t1 <- liftIO getMonotonicTime
  c <- liftIO $ readIORef cref
  let stats = ModStats
        { msModule = T.pack (prettyShow tlm)
        , msSkipped = False
        , msDefs = length defs
        , msBytes = bytes0 + sum [n | (_, n, _, _) <- results]
        , msSeconds = t1 - t0
        , msKinds = Map.fromListWith (+) [(k, 1) | (k, _, _, _) <- results]
        , msExplicit = cExplicit c
        , msStored = cStored c
        , msTreesExplicit = cTreesExplicit c
        , msTreesStored = cTreesStored c
        , msResidualProj = sum [p | (_, _, p, _) <- results]
        , msUnbound = sum [u | (_, _, _, u) <- results]
        , msReasons = cReasons c
        }
  liftIO $ logLine $ concat
    [ prettyShow tlm, ": ", show (msDefs stats), " defs, ", show (msBytes stats), " bytes, "
    , showFFloat (Just 2) (msSeconds stats) " s; explicit "
    , show (msExplicit stats), "/", show (msExplicit stats + msStored stats), " terms, "
    , show (msTreesExplicit stats), "/", show (msTreesExplicit stats + msTreesStored stats), " case trees"
    , if msUnbound stats > 0 then "; UNBOUND VARIABLES " ++ show (msUnbound stats) else ""
    ]
  return stats
  where
    writeOne h b = do
      let bs = B.toLazyByteString (b <> B.char7 '\n')
      BL.hPut h bs
      return (fromIntegral (BL.length bs))

-- | proj eliminations outside noparams: sites the reconstruction did not
--   reach (inside sorts, which it does not traverse).
residualProj :: Sexp -> Int
residualProj = \case
  L (A "noparams" : _) -> 0
  L xs@(A "proj" : _) -> 1 + sum (map residualProj xs)
  L xs -> sum (map residualProj xs)
  _ -> 0

moduleHeader :: Interface -> Int -> TCM Sexp
moduleHeader i n = do
  let tlm = iTopLevelModuleName i
  file <- tryTCM (filePath <$> (srcFilePath =<< findFile tlm))
  return $ L
    [ A "module"
    , str (prettyShow tlm)
    , L [A "name", moduleNameS (iModuleName i)]
    , L [A "file", either (const none) str file]
    , L (A "imports" : [str (prettyShow m) | (m, _) <- iImportedModules i])
    , L (A "options" : [str s | o <- iFilePragmaOptions i, s <- pragmaStrings o])
    , L (A "library-options" : [str s | o <- iDefaultPragmaOptions i, s <- pragmaStrings o])
    , L (A "builtins" : [builtinS k b | (k, b) <- Map.toList (iBuiltin i)])
    , L [A "defs", int n]
    ]
  where
    builtinS k b = L [A "builtin", str (getBuiltinId k), case b of
      Builtin t -> L [A "term", termS [] t]
      Prim (p, q) -> L [A "prim", str (getBuiltinId p), qnameS q]
      BuiltinRewriteRelations qs -> L (A "rewrite" : map qnameS (Set.toList qs))]

------------------------------------------------------------------------
-- A definition

encodeDef :: Env -> Definition -> TCM (Text, Sexp)
encodeDef env0 d = do
  let q = defName d
      n = qnameName q
      env = env0 { envDef = prettyShow q, envReasonPrefix = if defNoCompilation d then "no-compilation: " else "" }
  -- A copy made by module application (`open M args`, `module N = M args`)
  -- is the original applied to the arguments, which its case tree says.
  -- Its type and clauses are the original's with the arguments substituted
  -- at every occurrence of a parameter, written out as trees: 99% of a
  -- module like Categories.Category.Monoidal.Closed (86 MB).  So by default
  -- a copy function is written with (type none) and no clauses; a reader
  -- inlines its case tree where it is used (FORMAT.md, "Copies").
  let compact = defCopy d && isFun (theDef d) && not (optCopyTypes (envOpts env))
  ty <- if compact then return none
        else attempt env "type" (typS [] <$> explicitType (defType d)) (typS [] (defType d))
  (kind, extraFlags, details) <- defnS env { envCompact = compact } d (theDef d)
  let flags = [A f | (f, True) <-
                [ ("copy", defCopy d)
                , ("instance", isJust (defInstance d))
                , ("injective", defInjective d)
                , ("copattern-lhs", defCopatternLHS d)
                , ("no-compilation", defNoCompilation d)
                ]] ++ extraFlags
  return (kind, L
    [ A "def"
    , qnameS q
    , L [A "name", str (prettyShow (nameConcrete n))]
    , L [A "canonical", str (prettyShow (nameCanonical n))]
    , fixityS (theFixity (nameFixity n))
    , L [A "module", moduleNameS (qnameModule q)]
    , rangeS (nameBindingSite n)
    , linesS d
    , L [A "kind", A kind]
    , L (A "modality" : argInfoS (defArgInfo d))
    , L (A "flags" : flags)
    , L [A "language", languageA (defLanguage d)]
    , L [A "type", ty]
    , details
    ])

isFun :: Defn -> Bool
isFun = \case
  Function{} -> True
  _ -> False

fixityS :: Fixity -> Sexp
fixityS (Fixity _ lvl assoc) = case lvl of
  Unrelated -> L [A "fixity", none]
  Related p -> L [A "fixity", assocA, A (T.pack (precedence p))]
  where
    assocA = A $ case assoc of
      NonAssoc -> "infix"
      LeftAssoc -> "infixl"
      RightAssoc -> "infixr"
    precedence p
      | p == fromInteger (round p) = show (round p :: Integer)
      | otherwise = showFFloat Nothing p ""

languageA :: Language -> Sexp
languageA = \case
  WithoutK -> A "without-k"
  WithK -> A "with-k"
  Cubical CErased -> A "erased-cubical"
  Cubical CFull -> A "cubical"

-- | The first and last line the definition occupies in its file: its name,
--   and its clauses (a function), fields (a record) or constructors (data).
linesS :: Definition -> Sexp
linesS d = case rangeLines site of
  Nothing -> L [A "lines", none]
  Just (f, l1, l2) ->
    let ls = [(a, b) | Just (f', a, b) <- map rangeLines extra, f' == f]
    in L [A "lines", int (minimum (l1 : map fst ls)), int (maximum (l2 : map snd ls))]
  where
    site = nameBindingSite (qnameName (defName d))
    extra :: [Range]
    extra = case theDef d of
      Function{funClauses = cs} -> map clauseFullRange cs
      Record{recFields = fs} -> map (nameBindingSite . qnameName . unDom) fs
      Datatype{dataCons = cs} -> map (nameBindingSite . qnameName) cs
      _ -> []

-- | The kind, extra flags, and the kind's own fields.
defnS :: Env -> Definition -> Defn -> TCM (Text, [Sexp], Sexp)
defnS env d = \case
  AbstractDefn inner -> do
    (k, fl, s) <- defnS env d inner
    return (k, A "abstract-defn" : fl, s)
  Axiom{axiomConstTransp = ct} ->
    return ("postulate", [], L [A "postulate", L [A "const-transp", yesNo ct]])
  DataOrRecSig{datarecPars = n} ->
    return ("other", [], L [A "other", str "DataOrRecSig", L [A "pars", int n]])
  GeneralizableVar g ->
    return ("other", [], L [A "other", str "GeneralizableVar", L [A "args", case g of
      NoGeneralizableArgs -> none
      SomeGeneralizableArgs k -> int k]])
  PrimitiveSort{primSortName = nm, primSortSort = s} ->
    return ("other", [], L [A "other", str "PrimitiveSort", str (show nm), sortS [] s])
  Primitive{primAbstr = ab, primName = nm, primClauses = cs, primCompiled = cc, primOpaque = op} ->
    return ("primitive", [], L
      [ A "primitive"
      , str (getBuiltinId nm)
      , L [A "abstract", yesNo (ab == AbstractDef)]
      , L [A "opaque", yesNo (isOpaque op)]
      , L (A "clauses" : map storedClause cs)
      , L [A "compiled", maybe none (\c -> L [A "noparams", compiledS c]) cc]
      ])
  Constructor{conPars = np, conArity = ar, conSrcCon = ch, conData = dq, conAbstr = ab, conProj = pj, conForced = fo, conErased = er, conErasure = ers, conInline = inl} ->
    return ("constructor", [], L
      [ A "constructor"
      , L [A "data", qnameS dq]
      , L [A "pars", int np]
      , L [A "arity", int ar]
      , L [A "src-con", qnameS (conName ch)]
      , L [A "con-kind", dataOrRecordA (conDataRecord ch)]
      , L [A "induction", inductionA (conInductive ch)]
      , L (A "fields" : [L (A "field" : argInfoS ai ++ [qnameS f]) | Arg ai f <- conFields ch])
      , L (A "projections" : maybe [A "unknown"] (map qnameS) pj)
      , L (A "forced" : [yesNo (f == Forced) | f <- fo])
      , L (A "erased" : maybe [A "unknown"] (map yesNo) er)
      , L [A "erasure", yesNo ers]
      , L [A "inline", yesNo inl]
      , L [A "abstract", yesNo (ab == AbstractDef)]
      ])
  Datatype{dataPars = np, dataIxs = ni, dataClause = cl, dataCons = cs, dataSort = s, dataMutual = mu, dataAbstr = ab, dataPathCons = pcs} ->
    return ("data", [], L
      [ A "data"
      , L [A "pars", int np]
      , L [A "ixs", int ni]
      , L (A "cons" : map qnameS cs)
      , L [A "sort", sortS (reverse (take np (piNames (defType d)))) s]
      , mutualS mu
      , L [A "abstract", yesNo (ab == AbstractDef)]
      , L (A "path-cons" : map qnameS pcs)
      , L [A "clause", maybe none storedClause cl]
      ])
  Record{recPars = np, recClause = cl, recConHead = ch, recNamedCon = named, recFields = fs, recTel = tel, recMutual = mu, recEtaEquality' = eta, recPatternMatching = pm, recInduction = ind, recTerminates = ter, recAbstr = ab} -> do
    telS <- attempt env "record telescope" (telS <$> explicitTel tel) (telS tel)
    return ("record", [], L
      [ A "record"
      , L [A "pars", int np]
      , L [A "con", qnameS (conName ch)]
      , L [A "named-con", yesNo named]
      , L [A "induction", maybe none inductionA ind]
      , L (A "fields" : [L (A "field" : argInfoS (domInfo f) ++ [qnameS (unDom f)]) | f <- fs])
      , telS
      , etaS eta
      , L [A "pattern-matching", patternOrCopatternA pm]
      , mutualS mu
      , L [A "abstract", yesNo (ab == AbstractDef)]
      , L [A "terminates", maybeBool ter]
      , L [A "clause", maybe none storedClause cl]
      ])
  def@Function{funClauses = cs, funCompiled = mcc, funSplitTree = st, funMutual = mu, funProjection = pr, funFlags = fl, funTerminates = ter, funExtLam = el, funWith = wi, funOpaque = op} -> do
    -- A projection's or projection-like function's clauses and case tree
    -- may lack its first index-1 arguments (Agda drops them; its type
    -- keeps them).  The explicit form restores them as variable patterns,
    -- since its terms pass them at every call.
    let dropped = case pr of
          Right p | projIndex p > 1, optExplicit (envOpts env) ->
            take (projIndex p - 1) (getProjLams (projLams p))
          _ -> []
        missing = map (unboundTelVars) cs
        restoring = not (null dropped) && not (null cs) && all ((== length dropped) . length) missing
        consistent = null dropped || restoring || all null missing
    when (not consistent) $
      noteStoredWhy env "projection: dropped parameters not found" "projection: dropped parameters not found"
    let k = if restoring then length dropped else 0
        cs' = if restoring then map (restoreParams dropped) cs else cs
    encoded <- mapM (clauseS env) cs'
    tree <- case mcc of
      Nothing -> return none
      Just cc
        | consistent -> treeS env (defName d) cc (liftCompiled k (take k dropped) cc) (liftSplitTree k <$> st) [c | (_, c) <- encoded]
        | otherwise -> return (L [A "noparams", compiledS cc])
    return ("function", [], L
      [ A "function"
      , projectionS pr
      , L [A "restored-params", int k]
      , L [A "with-of", maybe none qnameS wi]
      , L (A "extlam" : maybe [none] (\x -> [moduleNameS (extLamModule x), L [A "absurd", yesNo (extLamAbsurd x)]]) el)
      , L [A "terminates", maybeBool ter]
      , mutualS mu
      , L (A "fun-flags" : map funFlagA (SmallSet.toList fl))
      , L [A "opaque", yesNo (isOpaque op)]
      , L [A "kan-op", maybe none qnameS (funIsKanOp def)]
      , L (A "clauses" : if envCompact env then [] else map fst encoded)
      , L [A "compiled", tree]
      ])
  where
    telS t = L (A "tel" : fst (telescopeS [] t))

-- | The names a type's leading Pis bind, outermost first (no reduction).
piNames :: Type -> [ArgName]
piNames (El _ t) = case t of
  Pi _ b -> absName b : piNames (unAbs b)
  _ -> []

isOpaque :: IsOpaque -> Bool
isOpaque = \case
  OpaqueDef{} -> True
  TransparentDef -> False

maybeBool :: Maybe Bool -> Sexp
maybeBool = maybe (A "unknown") yesNo

mutualS :: Maybe [QName] -> Sexp
mutualS = \case
  Nothing -> L [A "mutual", A "unknown"]
  Just qs -> L (A "mutual" : map qnameS qs)

inductionA :: Induction -> Sexp
inductionA = \case
  Inductive -> A "inductive"
  CoInductive -> A "coinductive"

dataOrRecordA :: DataOrRecord -> Sexp
dataOrRecordA = \case
  IsData -> A "data"
  IsRecord{} -> A "record"

patternOrCopatternA :: PatternOrCopattern -> Sexp
patternOrCopatternA = \case
  PatternMatching -> A "pattern"
  CopatternMatching -> A "copattern"

etaS :: EtaEquality -> Sexp
etaS e = L (A "eta" : origin : case theEtaEquality e of
  YesEta -> [A "yes"]
  NoEta pm -> [A "no", patternOrCopatternA pm])
  where
    origin = case e of
      Specified{} -> A "specified"
      Inferred{} -> A "inferred"

funFlagA :: FunctionFlag -> Sexp
funFlagA = \case
  FunStatic -> A "static"
  FunInline -> A "inline"
  FunMacro -> A "macro"
  FunFirstOrder -> A "first-order"
  FunErasure -> A "erasure"
  FunAbstract -> A "abstract"
  FunProj -> A "proj"

projectionS :: Either ProjectionLikenessMissing Projection -> Sexp
projectionS = \case
  Left _ -> L [A "projection", none]
  Right p -> L
    [ A "projection"
    , L [A "proper", maybe none qnameS (projProper p)]
    , L [A "orig", qnameS (projOrig p)]
    , L (A "from" : argInfoS (argInfoOf (projFromType p)) ++ [qnameS (unArg (projFromType p))])
    , L [A "index", int (projIndex p)]
    , L (A "lams" : [L (A "l" : argInfoS ai ++ [str x]) | Arg ai x <- getProjLams (projLams p)])
    ]
  where
    argInfoOf (Arg ai _) = ai

------------------------------------------------------------------------
-- Clauses and case trees

-- | A clause, and (when its body was made explicit) the clause with the
--   explicit body, for recompiling the case tree.
clauseS :: Env -> Clause -> TCM (Sexp, Clause)
clauseS env cl = do
  let tel = clauseTel cl
      cx = telNames tel
      telStored = L (A "tel" : fst (telescopeS [] tel))
      -- a clause the cubical-compatible translation generated (it matches
      -- on hcomp or transp, or on an interval variable)
      env' = if any (isCubicalPattern . namedThing . unArg) (namedClausePats cl)
               then env { envReasonPrefix = envReasonPrefix env <> "cubical clause: " }
               else env
  telE <- attempt env' "clause telescope" ((\t -> L (A "tel" : fst (telescopeS [] t))) <$> explicitTel tel) telStored
  (bodyS, body') <- case (clauseBody cl, clauseType cl) of
    (Nothing, _) -> return (A "absurd", Nothing)
    (Just v, Just (Arg _ t)) -> do
      (s, mv) <- attemptWith env' "clause body"
        ((\v' -> (termS cx v', v')) <$> addContext tel (explicitTerm t v))
        (termS cx v)
      return (s, Just (maybe (markStored v) id mv))
    (Just v, Nothing) -> do
      noteStoredWhy env' "clause has no type" "clause has no type"
      return (L [A "noparams", termS cx v], Just (markStored v))
  typeS <- case clauseType cl of
    Nothing -> return none
    Just (Arg ai t) -> do
      s <- attempt env' "clause type" (typS cx <$> addContext tel (explicitType t)) (typS cx t)
      return (L (A "of" : argInfoS ai ++ [s]))
  let sexp = L
        [ A "clause"
        , rangeS (clauseFullRange cl)
        , telE
        , L (A "pats" : map (namedPatternS cx) (namedClausePats cl))
        , L [A "body", bodyS]
        , L [A "type", typeS]
        , L [A "catchall", yesNo (case clauseCatchall cl of YesCatchall{} -> True; NoCatchall -> False)]
        , L [A "unreachable", maybeBool (clauseUnreachable cl)]
        , L [A "recursive", maybeBool (clauseRecursive cl)]
        , L [A "where-module", maybe none moduleNameS (clauseWhereModule cl)]
        ]
  return (sexp, cl { clauseBody = body' })
  where
    -- the stored body, marked so that its case-tree leaf is written as
    -- noparams (the clause compiler carries the mark through)
    markStored v = Dummy noparamsMark [Apply (defaultArg v)]

isCubicalPattern :: DeBruijnPattern -> Bool
isCubicalPattern = \case
  DefP{} -> True
  IApplyP{} -> True
  ConP _ _ ps -> any (isCubicalPattern . namedThing . unArg) ps
  _ -> False

-- | A clause exactly as stored (builtin clauses, the clause of a data or
--   record type made by module application).
storedClause :: Clause -> Sexp
storedClause cl = L
  [ A "clause"
  , rangeS (clauseFullRange cl)
  , L [A "noparams", L (A "tel" : fst (telescopeS [] (clauseTel cl)))]
  , L (A "pats" : map (namedPatternS cx) (namedClausePats cl))
  , L [A "body", maybe (A "absurd") (\v -> L [A "noparams", termS cx v]) (clauseBody cl)]
  , L [A "type", maybe none (\(Arg ai t) -> L (A "of" : argInfoS ai ++ [L [A "noparams", typS cx t]])) (clauseType cl)]
  , L [A "catchall", yesNo (case clauseCatchall cl of YesCatchall{} -> True; NoCatchall -> False)]
  , L [A "unreachable", maybeBool (clauseUnreachable cl)]
  , L [A "recursive", maybeBool (clauseRecursive cl)]
  , L [A "where-module", maybe none moduleNameS (clauseWhereModule cl)]
  ]
  where
    cx = telNames (clauseTel cl)

-- | The case tree: Agda's clause compiler (with the stored split tree, as
--   the backends recompile it) run again on the explicit clauses, whose
--   bodies that could not be made explicit carry a mark and come out as
--   noparams leaves.  It is used when it has the stored tree's shape, else
--   the stored tree is written whole as noparams.
treeS :: Env -> QName -> CompiledClauses -> CompiledClauses -> Maybe SplitTree -> [Clause] -> TCM Sexp
treeS env q cc ccLifted st cls = do
  let stored = L [A "noparams", compiledS cc]
      storedBecause why detail = do
        bump env (\c -> c { cTreesStored = cTreesStored c + 1, cReasons = Map.insertWith (+) (envReasonPrefix env <> why) 1 (cReasons c) })
        when (envDebug env) $ liftIO $ logLine ("stored tree: " ++ envDef env ++ ": " ++ T.unpack detail)
        return stored
  if not (optExplicit (envOpts env)) then return stored
  else if not (hasDone cc) then do
    -- no body anywhere (an absurd lambda, an absurd clause): nothing to
    -- reconstruct, the stored tree is the explicit one
    bump env (\c -> c { cTreesExplicit = cTreesExplicit c + 1 })
    return (compiledS cc)
  else do
    -- as Agda's ToTreeless.getCompiledClauses recompiles: no record pattern
    -- translation for a proper projection
    isProj <- isProperProjection . theDef <$> getConstInfo q
    let translate = if isProj then DontRunRecordPatternTranslation else RunRecordPatternTranslation
    res <- tryTCM (inTopContext (compiledS <$> compileClauses' q translate cls st))
    case res of
      Left ex -> storedBecause ("case tree: " <> reason False ex) (reason True ex)
      Right s
        | skeleton s == skeleton (compiledS ccLifted) -> do
            bump env (\c -> c { cTreesExplicit = cTreesExplicit c + 1 })
            return s
        | otherwise -> storedBecause "case tree: recompiled shape differs" $ T.pack $
            "recompiled " ++ take 700 (show (skeleton s)) ++ " stored " ++ take 700 (show (skeleton (compiledS ccLifted)))

-- | Whether a case tree has a body.
hasDone :: CompiledClauses -> Bool
hasDone = \case
  Done{} -> True
  Fail{} -> False
  Case _ br -> any hasDone br

-- | The telescope variables (de Bruijn indices, outermost first) that no
--   pattern of the clause binds.
unboundTelVars :: Clause -> [Int]
unboundTelVars cl = [i | i <- [n - 1, n - 2 .. 0], i `Set.notMember` bound]
  where
    n = size (clauseTel cl)
    bound = Set.fromList (concatMap (patVars . namedThing . unArg) (namedClausePats cl))
    patVars = \case
      VarP _ x -> [dbPatVarIndex x]
      IApplyP _ _ _ x -> [dbPatVarIndex x]
      ConP _ _ ps -> concatMap (patVars . namedThing . unArg) ps
      DefP _ _ ps -> concatMap (patVars . namedThing . unArg) ps
      _ -> []

-- | A projection(-like) function's clause with its dropped parameters back:
--   variable patterns for the telescope variables no pattern binds (as
--   many as were dropped), outermost first, with the argument information
--   Agda kept in projLams.
restoreParams :: [Arg ArgName] -> Clause -> Clause
restoreParams dropped cl =
  cl { namedClausePats = zipWith mk dropped (unboundTelVars cl) ++ namedClausePats cl }
  where
    mk (Arg ai x) i = Arg ai (Named Nothing (VarP (PatternInfo PatOSystem []) (DBPatVar x i)))

-- | The stored case tree with k restored leading arguments (for comparing
--   shapes with the tree recompiled from the restored clauses).
liftCompiled :: Int -> [Arg ArgName] -> CompiledClauses -> CompiledClauses
liftCompiled 0 _ cc = cc
liftCompiled k ps cc = case cc of
  Case i br -> Case ((+ k) <$> i) (liftCompiled k ps <$> br)
  Done xs t -> Done (ps ++ xs) t
  Fail xs -> Fail (ps ++ xs)

liftSplitTree :: Int -> SplitTree -> SplitTree
liftSplitTree 0 t = t
liftSplitTree k t = case t of
  SplittingDone m -> SplittingDone (m + k)
  SplitAt i lz ts -> SplitAt ((+ k) <$> i) lz [(tag, liftSplitTree k s) | (tag, s) <- ts]

-- | A case tree with its bodies blanked out.
skeleton :: Sexp -> Sexp
skeleton = \case
  L [A "done", vs, _] -> L [A "done", vs]
  L xs -> L (map skeleton xs)
  s -> s

-- | The statistics of one module, a line of _index.sexp.
statsSexp :: ModStats -> Sexp
statsSexp m = L
  [ A "module-stats"
  , S (msModule m)
  , L [A "skipped", yesNo (msSkipped m)]
  , L [A "defs", int (msDefs m)]
  , L [A "bytes", int (msBytes m)]
  , L [A "seconds", A (T.pack (showFFloat (Just 3) (msSeconds m) ""))]
  , L (A "kinds" : [L [A k, int n] | (k, n) <- Map.toList (msKinds m)])
  , L [A "explicit", int (msExplicit m)]
  , L [A "stored", int (msStored m)]
  , L [A "trees-explicit", int (msTreesExplicit m)]
  , L [A "trees-stored", int (msTreesStored m)]
  , L [A "residual-proj", int (msResidualProj m)]
  , L [A "unbound", int (msUnbound m)]
  , L (A "reasons" : [L [A "reason", S r, int n] | (r, n) <- Map.toList (msReasons m)])
  ]
