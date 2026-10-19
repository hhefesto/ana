{-# LANGUAGE MultiWayIf #-}

-- | The parameters Agda's internal syntax leaves out, put back.
--
--   Agda stores a projection as a postfix elimination (@r .f@) and a
--   projection-like function without its leading parameters; both lose the
--   record's (or data type's) parameters, which Bend must be given.  Agda's
--   own Agda.TypeChecking.ReconstructParameters recovers them by re-checking
--   the term with its internal checker (CheckInternal) and rewriting every
--   such site to @Def f (pars ++ [principal] ++ rest)@.
--
--   This module is that code (Agda 2.8.0's 'reconstruct', 'extractParameters'
--   and 'dropParameters'), with one change: constructor applications are left
--   as stored, without their data type's parameters, so that a 'Con' means
--   the same thing in every term of the export (the clause compiler's
--   catch-all expansion substitutes stored constructor terms into case-tree
--   bodies).  Nothing else is decided here.
module AgdaExport.Explicit
  ( explicitTerm
  , explicitType
  , explicitTel
  ) where

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.Syntax.Internal.Generic (TermLike, traverseTermM)
import Agda.TypeChecking.CheckInternal
import Agda.TypeChecking.Monad
import Agda.TypeChecking.ProjectionLike
import Agda.TypeChecking.Records (getDefType)
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Telescope
import Agda.Utils.Function (applyWhen)
import Agda.Utils.Impossible
import Agda.Utils.Lens ((^.))
import Agda.Utils.Size

-- | The term, checked against the type, with every projection and
--   projection-like application given its parameters.
explicitTerm :: Type -> Term -> TCM Term
explicitTerm a v = checkInternal' explicitAction v CmpLeq a

explicitType :: Type -> TCM Type
explicitType a = traverse (explicitTerm (sort $ getSort a)) a

explicitTel :: Telescope -> TCM Telescope
explicitTel EmptyTel = return EmptyTel
explicitTel (ExtendTel a tel) = do
  ar <- explicitType (unDom a)
  addContext (absName tel, a) $
    ExtendTel (ar <$ a) <$> traverse explicitTel tel

explicitAction :: Action TCM
explicitAction = defaultAction { postAction = explicitNode }

-- Agda's 'reconstruct' without its 'Con' case.
explicitNode :: Type -> Term -> TCM Term
explicitNode ty v = case v of
  Def f es -> projView v >>= \case
    ProjectionView _f a es' -> do
      recTy <- infer =<< dropProjParameters (unArg a)
      pars <- extractParams f recTy
      loop ty (Def f . (map Apply pars ++) . (Apply a :)) es'
    LoneProjectionLike _f _i -> reduce (unEl ty) >>= \case
      Pi recTy _ -> do
        pars <- extractParams f (unDom recTy)
        return $ Def f $ map Apply pars
      _ -> __IMPOSSIBLE__
    NoProjection{} -> do
      fty <- defType <$> getConstInfo f
      loop fty (Def f) es
  Var i es -> do
    vty <- typeOfBV i
    loop vty (Var i) es
  MetaV m es -> do
    mty <- getMetaType m
    loop mty (MetaV m) es
  _ -> return v
  where
    -- @loop t f es@: @t@ is the type of @f []@, @es@ valid eliminations of it
    loop :: Type -> (Elims -> Term) -> Elims -> TCM Term
    loop _ f [] = return $ f []
    loop t f (Apply u : es) = do
      uu <- dropProjParameters u
      t' <- piApplyM t uu
      loop t' (f . (Apply u :)) es
    loop t f (Proj _o p : es) = do
      pars <- extractParams p t
      mt <- getDefType p =<< reduce t
      b <- case mt of
        Just (El _ (Pi _ b)) -> return b
        _ -> __IMPOSSIBLE__
      let fTm = f []
      fe <- dropProjParameters fTm
      loop (absApp b fe) (Def p . (map Apply pars ++) . (Apply (defaultArg fTm) :)) es
    loop _ _ (IApply{} : _) = __IMPOSSIBLE__

-- Agda's 'extractParameters': the parameters, from the type of the
-- principal argument of a projection(-like) function.
extractParams :: QName -> Type -> TCM Args
extractParams q ty = reduce (unEl ty) >>= \case
  Def d prePs -> do
    dt <- defType <$> getConstInfo d
    postPs <- checkInternal' explicitAction prePs CmpEq (dt, Def d)
    info <- getConstInfo q
    let mkParam erasure =
            applyWhen erasure (applyQuantity zeroQuantity)
          . hideAndRelParams
          . isApplyElim' __IMPOSSIBLE__
    if
      | Constructor{ conPars = n, conErasure = e } <- theDef info ->
          return $ map (mkParam e) $ take n postPs
      | isProperProjection (theDef info) ->
          case theDef info of
            d@Function{} -> return $ map (mkParam (d ^. funErasure)) postPs
            _ -> __IMPOSSIBLE__
      | otherwise -> do
          TelV tel _ <- telViewUpTo (size postPs) $ defType info
          return $ zipWith (<$) (map (unArg . isApplyElim' __IMPOSSIBLE__) postPs) (teleArgs tel :: Args)
  _ -> __IMPOSSIBLE__

-- Agda's 'dropParameters' without its 'Con' case: back to Agda's own form,
-- so that the checker's types are computed from terms it understands.
dropProjParameters :: TermLike a => a -> TCM a
dropProjParameters = traverseTermM $ \case
  v@(Def f vs) -> isRelevantProjection f >>= \case
    Nothing -> return v
    Just pr -> return $ applyE (projDropPars pr ProjSystem) vs
  v -> return v
