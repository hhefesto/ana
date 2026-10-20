{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}

-- | The erasure sidecar (FORMAT.md, "The erasure sidecar"): for each
--   function, constructor, postulate and primitive of a module, which of its
--   parameters Agda's own compiler erases and which its compiled body never
--   uses, written to OUT/<Module.Name>.erasure.sexp.  It decides nothing;
--   it runs Agda's compiler front end and reports what it found.
--
--   Two sources, both Agda 2.8.0's:
--
--   * unused: 'Agda.Compiler.ToTreeless.toTreeless' compiles a function to
--     treeless syntax, and at its end 'Agda.Compiler.Treeless.Unused.usedArguments'
--     stores, per argument of the compiled function, whether the final body
--     uses it ('getCompiledArgUse').  These are the arguments the GHC
--     backend strips from a function's Haskell definition.
--
--   * erased: 'Agda.Compiler.Treeless.Erase.getFunInfo', which the eraser
--     ('eraseTerms') consults at every call site and replaces the argument
--     there by an erased value.  It is not exported, so this module carries a
--     copy of it and of 'getTypeInfo' (the type analysis), unchanged except
--     that each of the grounds 'mkR' combines is kept apart.
--
--   Functions are compiled as the GHC backend compiles them (lazy
--   evaluation, every module of the import closure in dependency order,
--   each module's definitions in 'sortDefs' order), because what a function
--   is found to use depends on what its callees use.
module AgdaExport.Erasure
  ( erasureModule
  , erasureFile
  ) where

import qualified Control.Exception as E
import Control.DeepSeq (NFData, force)
import Control.Monad (forM)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.State (StateT, evalStateT)
import Control.Monad.Trans.Class (lift)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as BL
import Data.IORef
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes, fromMaybe, isJust)
import GHC.Generics (Generic)
import qualified Data.Text as T
import GHC.Clock (getMonotonicTime)
import Numeric (showFFloat)
import System.Directory (createDirectoryIfMissing, doesFileExist, renameFile)
import System.FilePath ((</>))
import System.IO

import Agda.Compiler.Common (curIF, sortDefs)
import Agda.Compiler.ToTreeless (toTreeless)
import Agda.Syntax.Common
import Agda.Syntax.Common.Pretty (prettyShow)
import Agda.Syntax.Internal as I
import Agda.Syntax.Treeless (ArgUsage (..), EvaluationStrategy (..))
import Agda.TypeChecking.Monad as I
import Agda.TypeChecking.Primitive (getBuiltinName)
import Agda.TypeChecking.Substitute (TelV (..))
import Agda.TypeChecking.Telescope (telViewPath)
import Agda.Utils.Functor (dget)
import Agda.Utils.Lens
import Agda.Utils.Memo (memoRec)
import Agda.Utils.Monad (ifM)

import AgdaExport.Encode (qnameS)
import AgdaExport.Module (ModStats (..), Opts (..), logLine, skippedStats)
import AgdaExport.Sexp

-- | OUT/<Module.Name>.erasure.sexp
erasureFile :: FilePath -> TopLevelModuleName -> FilePath
erasureFile dir m = dir </> (prettyShow m ++ ".erasure.sexp")

------------------------------------------------------------------------
-- A module

-- | What compiling a function to treeless syntax gave.
data Outcome
  = OutTerm               -- ^ toTreeless made its own term
  | OutNoTerm             -- ^ toTreeless made none (Agda always inlines it: a
                        --   with-function or a non-recursive pattern lambda)
  | OutNotCompiled T.Text -- ^ Agda's backends never compile it
  | OutFailed T.Text      -- ^ toTreeless threw

-- | Compile every function of the module (whether or not its sidecar is
--   written: later modules' answers depend on this one's), then write one
--   line per function, constructor, postulate and primitive.
erasureModule :: Opts -> TopLevelModuleName -> TCM ModStats
erasureModule opts tlm = do
  let dir = maybe "." id (optDir opts)
      out = erasureFile dir tlm
      tmp = out ++ ".part"
      name = T.pack (prettyShow tlm)
  t0 <- liftIO getMonotonicTime
  i <- curIF
  let defs = map snd (sortDefs (iSignature i ^. sigDefinitions))
  -- pass 1: compile, in the order the backends compile (an inlined
  -- function's argument usage is set while its parent is compiled)
  compiled <- fmap Map.fromList $ forM defs $ \d -> (defName d,) <$> compileFun d
  there <- liftIO $ doesFileExist out
  if there && optSkipExisting opts then do
    t1 <- liftIO getMonotonicTime
    liftIO $ logLine $ prettyShow tlm ++ ": compiled, sidecar kept, " ++ showFFloat (Just 2) (t1 - t0) " s"
    return (skippedStats name)
  else do
    -- pass 2: what each definition's arguments are found to be
    entries <- catMaybes <$> mapM (\d -> entry d (Map.lookup (defName d) compiled)) defs
    let total f = sum (map f entries)
        failed = length [() | (_, OutFailed _) <- Map.toList compiled]
        header = L
          [ A "erasure-module", S name
          , L [A "version", int (1 :: Int)]
          , L [ A "sources"
              , L [A "erased", str "Agda.Compiler.Treeless.Erase.getFunInfo"]
              , L [A "unused", str "Agda.Compiler.Treeless.Unused.usedArguments"]
              ]
          , L [A "evaluation", A "lazy"]
          , L [A "entries", int (length entries)]
          , L [A "args", int (total eArgs)]
          , L [A "erased", int (total (length . eErased))]
          , L [A "unused", int (total (length . eUnused))]
          , L [A "failed", int failed]
          ]
    liftIO $ createDirectoryIfMissing True dir
    bytes <- liftIO $ withBinaryFile tmp WriteMode $ \h -> do
      ns <- mapM (writeOne h) (header : map eSexp entries)
      return (sum ns)
    liftIO $ renameFile tmp out
    t1 <- liftIO getMonotonicTime
    liftIO $ logLine $ concat
      [ prettyShow tlm, ": ", show (length entries), " entries, ", show (total eArgs), " args, "
      , show (total (length . eErased)), " erased, ", show (total (length . eUnused)), " unused"
      , if failed > 0 then ", toTreeless FAILED on " ++ show failed else ""
      , ", ", showFFloat (Just 2) (t1 - t0) " s"
      ]
    return (skippedStats name)
      { msSkipped = False
      , msDefs = length entries
      , msBytes = bytes
      , msSeconds = t1 - t0
      , msKinds = Map.fromListWith (+) [(eKind e, 1) | e <- entries]
      }
  where
    writeOne h s = do
      let bs = B.toLazyByteString (render s <> B.char7 '\n')
      BL.hPut h bs
      return (fromIntegral (BL.length bs) :: Int)

-- | Compile a function as the GHC backend does: not a definition Agda's
--   backends skip (cubical helpers, which 'curDefs' leaves out; a
--   definition whose modality is erased or irrelevant, which MAlonzo leaves
--   out), lazily evaluated.  The state is kept on success (the treeless
--   term and argument usage are stored in the signature, where the next
--   functions find them) and restored on failure.
compileFun :: Definition -> TCM Outcome
compileFun d = case theDef d of
  Function{}
    | defNoCompilation d -> return (OutNotCompiled "no-compilation")
    | not (usableModality (defArgInfo d)) -> return (OutNotCompiled "erased-definition")
    | otherwise -> do
        r <- tryKeep $ do
          t <- toTreeless LazyEvaluation (defName d)
          (t,) <$> getCompiledArgUse (defName d)
        return $ case r of
          Right (Just _, _) -> OutTerm
          Right (Nothing, _) -> OutNoTerm
          Left ex -> OutFailed (T.pack (take 200 (unwords (words (show ex)))))
  _ -> return (OutNotCompiled "not-a-function")

-- | Run a TCM action, keeping its state if it succeeds (its result forced)
--   and restoring the state if it throws a synchronous exception.
tryKeep :: NFData a => TCM a -> TCM (Either E.SomeException a)
tryKeep m = TCM $ \r e -> do
  s <- readIORef r
  (Right <$> (E.evaluate . force =<< unTCM m r e)) `E.catch` \(ex :: E.SomeException) ->
    case E.fromException ex of
      Just (async :: E.SomeAsyncException) -> E.throwIO async
      Nothing -> do
        writeIORef r s
        return (Left ex)

------------------------------------------------------------------------
-- A definition

data Entry = Entry
  { eKind :: T.Text
  , eArgs :: Int
  , eErased :: [Int]
  , eUnused :: [Int]
  , eSexp :: Sexp
  }
  deriving (Generic, NFData)

-- | The line of one function, constructor, postulate or primitive (other
--   kinds get none).
entry :: Definition -> Maybe Outcome -> TCM (Maybe Entry)
entry d0 mc = do
  -- the definition as it is now, with its compiled form stored
  d <- getConstInfo (defName d0)
  case kindOf (theDef d) of
    Nothing -> return Nothing
    Just kind -> do
      r <- tryKeep (entryOf kind d (fromMaybe (OutNotCompiled "not-a-function") mc))
      return $ Just $ case r of
        Right e -> e
        -- the analysis itself threw: the line says so, and carries no lists
        Left ex -> Entry kind 0 [] [] (L [A "erasure", qnameS (defName d), L [A "error", S (T.pack (take 200 (unwords (words (show ex)))))]])
  where
    kindOf = \case
      Function{} -> Just "function"
      Constructor{} -> Just "constructor"
      Axiom{} -> Just "postulate"
      Primitive{} -> Just "primitive"
      AbstractDefn inner -> kindOf inner
      _ -> Nothing

entryOf :: T.Text -> Definition -> Outcome -> TCM Entry
entryOf kind d c = do
  let q = defName d
  -- Erase.typeWithoutParams: the type's telescope (telViewPath reduces
  -- the type where it must to expose a Pi), less the parameters the
  -- compiled code never takes
  TelV tel0 _ <- telViewPath (defType d)
  let tel = telToList tel0
      n = length tel
      k = min n (droppedParams (theDef d))
  facts <- funInfo q
  use <- getCompiledArgUse q
  let dropped = [0 .. k - 1]
      at f = [k + j | (j, a) <- zip [0 ..] (afArgs facts), f a]
      modality = at afModality
      forced = at afForced
      byType = at ((== Erasable) . afType)
      byEmpty = at ((== Empty) . afType)
      -- the compiled function's arguments (as many as its treeless term has
      -- lambdas), counted after the dropped parameters; Agda takes the ones
      -- past the end as used
      unusedC = [k + j | (j, ArgUnused) <- zip [0 ..] (fromMaybe [] use)]
      erased = [i | i <- [0 .. max n (k + length (fromMaybe [] use)) - 1]
                  , i `elem` dropped || i `elem` modality || i `elem` forced
                    || i `elem` unusedC || i `elem` byType || i `elem` byEmpty]
      unused = dropped ++ unusedC
      ints = map int
      compiledS = case c of
        OutTerm -> [A "compiled"]
        OutNoTerm | isJust use -> [A "inlined"]
               | otherwise -> [A "none"]
        OutNotCompiled why -> [A "not-compiled", A why]
        OutFailed why -> [A "failed", S why]
  return Entry
    { eKind = kind
    , eArgs = n
    , eErased = erased
    , eUnused = unused
    , eSexp = L
        [ A "erasure"
        , qnameS q
        , L [A "args", int n]
        , L (A "erased" : ints erased)
        , L (A "unused" : ints unused)
        , L [A "pis", int (piCount (defType d))]
        , L (A "names" : [str x | dom <- tel, let (x, _) = unDom dom])
        , L [A "kind", A kind]
        , L [A "dropped", int k]
        , L [A "arity", maybe none (int . length) use]
        , L [A "result", typeInfoA (afResult facts)]
        , L [ A "why"
            , L (A "dropped" : ints dropped)
            , L (A "modality" : ints modality)
            , L (A "forced" : ints forced)
            , L (A "unused" : ints unusedC)
            , L (A "type" : ints byType)
            , L (A "empty" : ints byEmpty)
            ]
        , L (A "treeless" : compiledS)
        ]
    }

-- | How many leading parameters the compiled code never takes (Erase's
--   typeWithoutParams, MAlonzo's functionViaTreeless): a projection's or
--   projection-like function's index-1 parameters, a constructor's data
--   parameters.
droppedParams :: Defn -> Int
droppedParams = \case
  Function{funProjection = Right Projection{projIndex = i}} -> max 0 (i - 1)
  Constructor{conPars = np} -> np
  _ -> 0

typeInfoA :: TypeInfo -> Sexp
typeInfoA = \case
  Erasable -> A "erasable"
  Empty -> A "empty"
  NotErasable -> A "not-erasable"

------------------------------------------------------------------------
-- Agda.Compiler.Treeless.Erase (2.8.0), copied: getFunInfo and
-- getTypeInfo are not exported.  The only change: getFunInfo's mkR
-- combines four grounds into one TypeInfo per argument; here each ground
-- is kept, and FORMAT.md's `erased` is their union, as mkR's.

data TypeInfo = Empty | Erasable | NotErasable
  deriving (Eq, Show)

sumTypeInfo :: [TypeInfo] -> TypeInfo
sumTypeInfo is = foldr plus Empty is
  where
    plus Empty       r           = r
    plus r           Empty       = r
    plus Erasable    r           = r
    plus r           Erasable    = r
    plus NotErasable NotErasable = NotErasable

erasable :: TypeInfo -> Bool
erasable Erasable    = True
erasable Empty       = True
erasable NotErasable = False

-- | One argument after the dropped parameters: the grounds of getFunInfo's
--   mkR (its argument usage is read separately).
data ArgFacts = ArgFacts
  { afModality :: Bool   -- ^ not (usableModality m): irrelevant, shape-irrelevant or @0
  , afForced :: Bool     -- ^ a forced constructor argument
  , afType :: TypeInfo   -- ^ getTypeInfo of the argument's type
  }

data FunFacts = FunFacts
  { afArgs :: [ArgFacts]
  , afResult :: TypeInfo -- ^ getFunInfo's second component
  }

-- | Eraser monad: the memo table of data and record types.
type E = StateT (Map.Map QName TypeInfo) TCM

-- | getFunInfo, in a fresh eraser state (as 'isErasable' runs it).
funInfo :: QName -> TCM FunFacts
funInfo q = flip evalStateT Map.empty $ do
  (tel, t) <- lift $ typeWithoutParams q
  is <- mapM (getTypeInfo . snd . dget) tel
  forced <- lift $ (++ repeat NotForced) <$> getForcedArgs q
  let args = [ ArgFacts (not (usableModality (getModality dom))) (f == Forced) i
             | (dom, f, i) <- zip3 tel forced is ]
  h <- if isAbsurdLambdaName q then pure Erasable else getTypeInfo t
  return (FunFacts args h)

telListView :: Type -> TCM (ListTel, Type)
telListView t = do
  TelV tel t <- telViewPath t
  return (telToList tel, t)

typeWithoutParams :: QName -> TCM (ListTel, Type)
typeWithoutParams q = do
  def <- getConstInfo q
  let d = case I.theDef def of
        Function{ funProjection = Right Projection{ projIndex = i } } -> i - 1
        Constructor{ conPars = n } -> n
        _                          -> 0
  (\(tel, t) -> (drop d tel, t)) <$> telListView (defType def)

getTypeInfo :: Type -> E TypeInfo
getTypeInfo t0 = do
  (tel, t) <- lift $ telListView t0
  et <- case I.unEl t of
    I.Def d _ -> do
      -- #2916: Only update the memo table for d. Results for other types are
      -- under the assumption that d is erasable!
      oldMap <- use id
      dInfo <- typeInfo d
      id .= Map.insert d dInfo oldMap
      return dInfo
    Sort{}    -> return Erasable
    _         -> return NotErasable
  is <- mapM (getTypeInfo . snd . dget) tel
  let e | Empty `elem` is = Erasable
        | null is         = et        -- TODO: guard should really be "all inhabited is"
        | et == Empty     = Erasable
        | otherwise       = et
  return e
  where
  typeInfo :: QName -> E TypeInfo
  typeInfo q = ifM (erasureForbidden q) (return NotErasable) $ {-else-} do
    memoRec (key q) Erasable $ do  -- assume recursive occurrences are erasable
      msizes <- lift $ mapM getBuiltinName
                         [builtinSize, builtinSizeLt]
      def    <- lift $ getConstInfo q
      let mcs = case I.theDef def of
                  I.Datatype{ dataCons = cs } -> Just cs
                  I.Record{ recConHead = c }  -> Just [conName c]
                  _                           -> Nothing
      case mcs of
        _ | Just q `elem` msizes -> return Erasable
        Just [c] -> do
          (ts, _) <- lift $ typeWithoutParams c
          let rs = map getModality ts
          is <- mapM (getTypeInfo . snd . dget) ts
          let er = and [ erasable i || not (usableModality r) | (i, r) <- zip is rs ]
          return $ if er then Erasable else NotErasable
        Just []      -> return Empty
        Just (_:_:_) -> return NotErasable
        Nothing ->
          case I.theDef def of
            I.Function{ funClauses = cs } ->
              sumTypeInfo <$> mapM (maybe (return Empty) (getTypeInfo . El __DUMMY_SORT__) . clauseBody) cs
            _ -> return NotErasable
  -- The backend also has a say whether a type is eraseable or not.
  erasureForbidden :: QName -> E Bool
  erasureForbidden q = lift $ not <$> activeBackendMayEraseType q

-- | The Pis the type shows, without reduction (the main export's type has
--   these; telViewPath may expose more by reducing the codomain).
piCount :: Type -> Int
piCount (El _ t) = case t of
  Pi _ b -> 1 + piCount (unAbs b)
  _ -> 0
