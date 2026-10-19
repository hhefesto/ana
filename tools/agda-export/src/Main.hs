-- | agda-export: Agda 2.8.0 with one more backend.  `agda-export
--   --export-dir=OUT FILE.agda` type-checks FILE (loading up-to-date
--   interfaces as agda does) and writes, for FILE and every module it
--   imports (transitively, Agda.Primitive included), OUT/<Module>.sexp: the
--   module header and one S-expression per definition (FORMAT.md), plus
--   OUT/_index.sexp with each module's counts.  Every other flag is agda's.
module Main (main) where

import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString.Builder as B
import qualified Data.Map as Map
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withBinaryFile)

import Agda.Compiler.Backend
import Agda.Main (runAgda)
import Agda.Utils.GetOpt (ArgDescr (..), OptDescr (..))
import Agda.Syntax.Common.Pretty (prettyShow)
import qualified Data.Text as T

import AgdaExport.Module
import AgdaExport.Sexp

main :: IO ()
main = runAgda [Backend backend]

backend :: Backend' Opts Opts () ModStats ()
backend = Backend'
  { backendName = "agda-export"
  , backendVersion = Just "0.1.0"
  , options = defaultOpts
  , commandLineFlags =
      [ Option [] ["export-dir"] (ReqArg (\d o -> pure o { optDir = Just d }) "DIR")
          "write every module's elaborated definitions to DIR/<Module>.sexp (agda2bend's front end)"
      , Option [] ["export-pretty"] (NoArg (\o -> pure o { optPretty = True }))
          "indent the S-expressions (agda-export)"
      , Option [] ["export-stored-only"] (NoArg (\o -> pure o { optExplicit = False }))
          "write the terms as Agda stores them, without reconstructing projection parameters (agda-export)"
      , Option [] ["export-skip-existing"] (NoArg (\o -> pure o { optSkipExisting = True }))
          "keep a module whose DIR/<Module>.sexp already exists (agda-export)"
      , Option [] ["export-copy-types"] (NoArg (\o -> pure o { optCopyTypes = True }))
          "write the copies a module application makes in full, type and clauses included (agda-export)"
      ]
  , isEnabled = \o -> maybe False (const True) (optDir o)
  , preCompile = \o -> do
      liftIO $ mapM_ (createDirectoryIfMissing True) (optDir o)
      liftIO $ logLine $ "exporting to " ++ maybe "?" id (optDir o)
          ++ (if optExplicit o then "" else " (stored terms only)")
      return o
  , postCompile = \o _ mods -> liftIO $ writeIndex o (Map.elems mods)
  , preModule = \o _ m _ -> case optDir o of
      Just dir | optSkipExisting o -> do
        there <- liftIO $ doesFileExist (moduleFile dir m)
        return $ if there then Skip (skippedStats (T.pack (prettyShow m))) else Recompile ()
      _ -> return (Recompile ())
  , postModule = \o () _ m _ -> exportModule o m
  , compileDef = \_ _ _ _ -> return ()
  , scopeCheckingSuffices = False
  , mayEraseType = \_ -> return True
  , backendInteractTop = Nothing
  , backendInteractHole = Nothing
  }

-- | _index.sexp: one module-stats line per module, then the totals.
writeIndex :: Opts -> [ModStats] -> IO ()
writeIndex o ms = case optDir o of
  Nothing -> return ()
  Just dir -> do
    let total f = sum (map f ms)
        kinds = Map.toList (Map.unionsWith (+) (map msKinds ms))
        reasons = Map.toList (Map.unionsWith (+) (map msReasons ms))
        totals = L
          [ A "total"
          , L [A "modules", int (length ms)]
          , L [A "skipped", int (length (filter msSkipped ms))]
          , L [A "defs", int (total msDefs)]
          , L [A "bytes", int (total msBytes)]
          , L (A "kinds" : [L [A k, int n] | (k, n) <- kinds])
          , L [A "explicit", int (total msExplicit)]
          , L [A "stored", int (total msStored)]
          , L [A "trees-explicit", int (total msTreesExplicit)]
          , L [A "trees-stored", int (total msTreesStored)]
          , L [A "residual-proj", int (total msResidualProj)]
          , L [A "unbound", int (total msUnbound)]
          , L (A "reasons" : [L [A "reason", S r, int n] | (r, n) <- reasons])
          ]
    withBinaryFile (dir </> "_index.sexp") WriteMode $ \h ->
      B.hPutBuilder h (mconcat [render s <> B.char7 '\n' | s <- map statsSexp ms ++ [totals]])
    logLine $ concat
      [ show (length ms), " modules, ", show (total msDefs), " defs, ", show (total msBytes), " bytes; "
      , unwords [T.unpack k ++ "=" ++ show n | (k, n) <- kinds]
      , "; explicit ", show (total msExplicit), " stored ", show (total msStored)
      , "; trees explicit ", show (total msTreesExplicit), " stored ", show (total msTreesStored)
      ]
