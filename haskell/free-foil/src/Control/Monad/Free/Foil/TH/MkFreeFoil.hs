{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns    #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# HLINT ignore "Use ++" #-}
-- | Template Haskell generation for Free Foil (generic scope-safe representation of syntax).
module Control.Monad.Free.Foil.TH.MkFreeFoil (
  FreeFoilConfig(..),
  FreeFoilTermConfig(..),
  mkFreeFoil,
  mkFreeFoilConversions,
) where

import           Language.Haskell.TH
import           Language.Haskell.TH.Syntax (addModFinalizer)

import           Control.Monad              (forM, forM_, when)
import qualified Control.Monad.Foil         as Foil
import           Control.Monad.Foil.TH.Util
import qualified Control.Monad.Free.Foil    as Foil
import           Data.Bifunctor
import           Data.List                  (find, unzip4, (\\), nub)
import           Data.Maybe                 (catMaybes, mapMaybe)
import Data.Map (Map)
import qualified Data.Map as Map
import qualified GHC.Generics               as GHC

-- | Config for the Template Haskell generation of data types,
-- pattern synonyms, and conversion functions for the Free Foil representation,
-- based on a raw recursive representation.
data FreeFoilConfig = FreeFoilConfig
  { rawQuantifiedNames        :: [Name]
  -- ^ Names of raw types that may include other binders and terms as components.
  -- Some examples of syntax that might be suitable here:
  --
  --  1. a type scheme in HM-style type system (to explicitly disallow nested forall)
  --  2. defining equation of a function (which itself is not a term)
  --  3. data or type synonym declaration (which itself is not a type)
  --  4. unification constraints (quantified or not)
  , freeFoilTermConfigs       :: [FreeFoilTermConfig]
  -- ^ Configurations for each term (e.g. expressions, types) group.
  , freeFoilNameModifier      :: String -> String
  -- ^ Name modifier for the Free Foil conterpart of a raw type name.
  -- Normally, this is just 'id'.
  , freeFoilScopeNameModifier :: String -> String
  -- ^ Name modifier for the scoped Free Foil conterpart of a raw type name.
  -- Normally, this is something like @("Scoped" ++)@.
  , signatureNameModifier     :: String -> String
  -- ^ Name modifier for the signature conterpart of a raw type name or raw constructor name.
  -- Normally, this is something like @(++ "Sig")@.
  , freeFoilConNameModifier   :: String -> String
  -- ^ Name modifier for the Free Foil conterpart (pattern synonym) of a raw constructor name.
  -- Normally, this is just 'id'.
  , freeFoilConvertToName     :: String -> String
  -- ^ Name of a conversion function (from raw to scope-safe) for a raw type name.
  -- Normally, this is something like @("to" ++)@.
  , freeFoilConvertFromName   :: String -> String
  -- ^ Name of a conversion function (from scope-safe to raw) for a raw type name.
  -- Normally, this is something like @("from" ++)@.
  }

-- | Config for a single term group,
-- for the Template Haskell generation of data types,
-- pattern synonyms, and conversion functions for the Free Foil representation,
-- based on a raw recursive representation.
data FreeFoilTermConfig = FreeFoilTermConfig
  { rawIdentName          :: Name
    -- ^ The type name for the identifiers.
    -- When identifiers occur in a term, they are converted to 'Foil.Name' (with an appropriate type-level scope parameter).
    -- When identifiers occur in a pattern, they are converted to 'Foil.NameBinder' (with appropriate type-level scope parameters).
  , rawTermName           :: Name
    -- ^ The type name for the term.
    -- This will be the main recursive type to be converted into an 'Foil.AST'.
  , rawBindingName        :: Name
    -- ^ The type name for the binders (patterns).
    -- This will be the main binder type to used in 'Foil.AST'-representation of the terms.
  , rawScopeName          :: Name
    -- ^ The type name for the scoped term.
    -- This will be replaced with either 'Foil.ScopedAST' (with outer scope) or 'Foil.AST' (with inner scope)
    -- depending on its occurrence in a regular (sub)term or some quantified syntax.
  , rawVarConName         :: Name
    -- ^ The constructor name for the variables in a term.
    -- This constructor will be replaced with the standard 'Foil.Var'.
    -- It is expected to have exactly one field of type 'rawIdentName'.
  , rawSubTermNames       :: [Name]
    -- ^ Type names for subterm syntax.
    -- This will rely on the main term type ('rawTermName') for recursive occurrences.
    -- Template Haskell will also generate signatures for these.
  , rawSubScopeNames      :: [Name]
    -- ^ Type names for scoped subterm syntax.
    -- This will rely on the main term type ('rawTermName') for recursive occurrences.
    -- Template Haskell will also generate signatures for these.
  , intToRawIdentName     :: Name
    -- ^ Name of a function that converts 'Int' to a raw identifier.
    -- Normally, this is something like @(\i -> VarIdent ("x" ++ show i))@.
    -- This is required to generate standard conversions from scope-safe to raw representation.
  , rawVarIdentToTermName :: Name
    -- ^ Name of a function that converts a raw identifier into a raw term.
    -- Normally, this is some kind of @Var@ or @TypeVar@ data constructor.
    -- This is required to generate standard conversions from scope-safe to raw representation.
  , rawTermToScopeName    :: Name
    -- ^ Name of a function that converts a raw term into a raw scoped term.
    -- Normally, this is some kind of @ScopedTerm@ or @ScopedType@ data constructor.
  , rawScopeToTermName    :: Name
    -- ^ Name of a function that extracts a raw term from a raw scoped term.
    -- Normally, this is something like @(\(ScopedTerm term) -> term)@.
  }

toFreeFoilName :: FreeFoilConfig -> Name -> Name
toFreeFoilName FreeFoilConfig{..} name = mkName (freeFoilNameModifier (nameBase name))

toFreeFoilNameFrom :: FreeFoilConfig -> Name -> Name
toFreeFoilNameFrom FreeFoilConfig{..} name = mkName (freeFoilConvertFromName (nameBase name))

toFreeFoilNameTo :: FreeFoilConfig -> Name -> Name
toFreeFoilNameTo FreeFoilConfig{..} name = mkName (freeFoilConvertToName (nameBase name))

toFreeFoilScopedName :: FreeFoilConfig -> Name -> Name
toFreeFoilScopedName FreeFoilConfig{..} name = mkName (freeFoilScopeNameModifier (nameBase name))

toSignatureName :: FreeFoilConfig -> Name -> Name
toSignatureName FreeFoilConfig{..} name = mkName (signatureNameModifier (nameBase name))

toConName :: FreeFoilConfig -> Name -> Name
toConName FreeFoilConfig{..} name = mkName (freeFoilConNameModifier (nameBase name))

lookupIdentName :: Name -> [FreeFoilTermConfig] -> Maybe FreeFoilTermConfig
lookupIdentName name = find (\FreeFoilTermConfig{..} -> rawIdentName == name)

lookupTermName :: Name -> [FreeFoilTermConfig] -> Maybe FreeFoilTermConfig
lookupTermName name = find (\FreeFoilTermConfig{..} -> rawTermName == name)

lookupSubTermName :: Name -> [FreeFoilTermConfig] -> Maybe FreeFoilTermConfig
lookupSubTermName name = find (\FreeFoilTermConfig{..} -> name `elem` rawSubTermNames)

lookupSubScopeName :: Name -> [FreeFoilTermConfig] -> Maybe FreeFoilTermConfig
lookupSubScopeName name = find (\FreeFoilTermConfig{..} -> name `elem` rawSubScopeNames)

lookupBindingName :: Name -> [FreeFoilTermConfig] -> Maybe FreeFoilTermConfig
lookupBindingName name = find (\FreeFoilTermConfig{..} -> rawBindingName == name)

lookupScopeName :: Name -> [FreeFoilTermConfig] -> Maybe FreeFoilTermConfig
lookupScopeName name = find (\FreeFoilTermConfig{..} -> rawScopeName == name)

data Sort
  = SortBinder | SortTerm | SortSubTerm

toFreeFoilType :: Sort -> FreeFoilConfig -> Type -> Type -> Type -> Type
toFreeFoilType isBinder config@FreeFoilConfig{..} outerScope innerScope = go
  where
    go = \case
      PeelConT typeName (map go -> typeParams)
        | typeName `elem` rawQuantifiedNames ->
            PeelConT (toFreeFoilName config typeName) (typeParams ++ [outerScope])
        | typeName `elem` map rawIdentName freeFoilTermConfigs ->
            case isBinder of
              SortBinder -> PeelConT ''Foil.NameBinder [outerScope, innerScope]
              _          -> PeelConT ''Foil.Name [outerScope]
        | Just _ <- lookupTermName typeName freeFoilTermConfigs ->
            PeelConT (toFreeFoilName config typeName) (typeParams ++ [outerScope])
        | Just _ <- lookupBindingName typeName freeFoilTermConfigs ->
            PeelConT (toFreeFoilName config typeName) (typeParams ++ [outerScope, innerScope])
        | Just FreeFoilTermConfig{..} <- lookupScopeName typeName freeFoilTermConfigs ->
            PeelConT (toFreeFoilName config rawTermName) (typeParams ++ [innerScope])
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs ->
            PeelConT (toFreeFoilName config typeName) (typeParams ++ [outerScope])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs ->
            PeelConT (toFreeFoilName config typeName) (typeParams ++ [innerScope])
      ForallT bndrs ctx type_ -> ForallT bndrs ctx (go type_)
      ForallVisT bndrs type_ -> ForallVisT bndrs (go type_)
      AppT f x -> AppT (go f) (go x)
      AppKindT f k -> AppKindT (go f) k
      SigT t k -> SigT (go t) k
      t@ConT{} -> t
      t@VarT{} -> t
      t@PromotedT{} -> t
      InfixT l op r -> InfixT (go l) op (go r)
      UInfixT l op r -> UInfixT (go l) op (go r)
      PromotedInfixT l op r -> PromotedInfixT (go l) op (go r)
      PromotedUInfixT l op r -> PromotedUInfixT (go l) op (go r)
      ParensT t -> ParensT (go t)
      t@TupleT{} -> t
      t@UnboxedTupleT{} -> t
      t@UnboxedSumT{} -> t
      t@ArrowT{} -> t
      t@MulArrowT{} -> t
      t@EqualityT{} -> t
      t@ListT{} -> t
      t@PromotedTupleT{} -> t
      t@PromotedNilT{} -> t
      t@PromotedConsT{} -> t
      t@StarT{} -> t
      t@ConstraintT{} -> t
      t@LitT{} -> t
      t@WildCardT{} -> t
      ImplicitParamT s t -> ImplicitParamT s (go t)

toFreeFoilSigType :: Sort -> FreeFoilConfig -> Type -> Type -> Type -> Maybe Type
toFreeFoilSigType sort config@FreeFoilConfig{..} scope term = go
  where
    go :: Type -> Maybe Type
    go = \case
      PeelConT _typeName (mapM go -> Nothing) ->
        error "bad type params"
      PeelConT typeName (mapM go -> Just typeParams)
        | Just _ <- lookupTermName typeName freeFoilTermConfigs ->
            case sort of
              SortSubTerm -> Just (PeelConT (toSignatureName config typeName) (typeParams ++ [scope, term]))
              _           -> Just term
        | Just _ <- lookupBindingName typeName freeFoilTermConfigs ->
            Nothing
        | Just _ <- lookupScopeName typeName freeFoilTermConfigs ->
            Just scope
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs ->
            Just (PeelConT (toSignatureName config typeName) (typeParams ++ [scope, term]))
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs ->
            Just (PeelConT (toSignatureName config typeName) (typeParams ++ [scope, term]))
      ForallT bndrs ctx type_ -> ForallT bndrs ctx <$> go type_
      ForallVisT bndrs type_ -> ForallVisT bndrs <$> go type_
      AppT f x -> AppT <$> go f <*> go x
      AppKindT f k -> AppKindT <$> go f <*> pure k
      SigT t k -> SigT <$> go t <*> pure k
      t@ConT{} -> pure t
      t@VarT{} -> pure t
      t@PromotedT{} -> pure t
      InfixT l op r -> InfixT <$> go l <*> pure op <*> go r
      UInfixT l op r -> UInfixT <$> go l <*> pure op <*> go r
      PromotedInfixT l op r -> PromotedInfixT <$> go l <*> pure op <*> go r
      PromotedUInfixT l op r -> PromotedUInfixT <$> go l <*> pure op <*> go r
      ParensT t -> ParensT <$> go t
      t@TupleT{} -> pure t
      t@UnboxedTupleT{} -> pure t
      t@UnboxedSumT{} -> pure t
      t@ArrowT{} -> pure t
      t@MulArrowT{} -> pure t
      t@EqualityT{} -> pure t
      t@ListT{} -> pure t
      t@PromotedTupleT{} -> pure t
      t@PromotedNilT{} -> pure t
      t@PromotedConsT{} -> pure t
      t@StarT{} -> pure t
      t@ConstraintT{} -> pure t
      t@LitT{} -> pure t
      t@WildCardT{} -> pure t
      ImplicitParamT s t -> ImplicitParamT s <$> go t

toFreeFoilCon :: FreeFoilConfig -> Type -> Type -> Type -> Con -> Q Con
toFreeFoilCon config rawRetType outerScope innerScope = go
  where
    goType = toFreeFoilType SortTerm config outerScope innerScope
    go = \case
      GadtC conNames argTypes retType -> do
        let newConNames = map (toConName config) conNames
        forM_ (zip conNames newConNames) $ \(conName, newConName) ->
          addModFinalizer $ putDoc (DeclDoc newConName)
            ("Corresponds to '" ++ show conName ++ "'.")
        return (GadtC newConNames (map (fmap goType) argTypes) (goType retType))
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC params ctx con -> ForallC params ctx <$> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

toFreeFoilSigCon :: FreeFoilConfig -> FreeFoilTermConfig -> Name -> Type -> Type -> Type -> Con -> Q (Maybe Con)
toFreeFoilSigCon config FreeFoilTermConfig{..} sigName rawRetType scope term = go
  where
    goType = toFreeFoilSigType SortTerm config scope term
    go = \case
      GadtC conNames argTypes retType
        | null newConNames -> pure Nothing
        | otherwise -> do
            forM_ (zip conNames newConNames) $ \(conName, newConName) ->
              addModFinalizer $ putDoc (DeclDoc newConName)
                ("Corresponds to '" ++ show conName ++ "'.")
            return (Just (GadtC newConNames newArgTypes theRetType))
        where
          newArgTypes = mapMaybe (traverse goType) argTypes
          newConNames =
            [ toSignatureName config rawConName
            | rawConName <- conNames
            , rawConName /= rawVarConName ]
          theRetType =
            case retType of
              PeelConT _rawTypeName (mapM goType -> Just params) ->
                PeelConT sigName (params ++ [scope, term])
              _ -> error "unexpected return type!"
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC params ctx con -> fmap (ForallC params ctx) <$> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

toFreeFoilBindingCon :: FreeFoilConfig -> Type -> Type -> Con -> Q Con
toFreeFoilBindingCon config rawRetType theOuterScope = go
  where
    goType = toFreeFoilType SortBinder config theOuterScope

    goTypeArgs :: Int -> Type -> [BangType] -> Q (Type, [BangType])
    goTypeArgs _ outerScope [] = pure (outerScope, [])
    goTypeArgs i outerScope ((bang_, rawArgType) : rawArgs) = do
      case rawArgType of
        PeelConT rawTypeName _rawTypeParams
          | rawTypeName `elem` map rawIdentName (freeFoilTermConfigs config) -> do
            innerScope <- VarT <$> newName ("i" <> show i)
            let argType = toFreeFoilType SortBinder config outerScope innerScope rawArgType
            (theInnerScope, argTypes) <- goTypeArgs (i + 1) innerScope rawArgs
            return (theInnerScope, ((bang_, argType) : argTypes))

          | Just _ <- lookupBindingName rawTypeName (freeFoilTermConfigs config) -> do
            innerScope <- VarT <$> newName ("i" <> show i)
            let argType = toFreeFoilType SortBinder config outerScope innerScope rawArgType
            (theInnerScope, argTypes) <- goTypeArgs (i + 1) innerScope rawArgs
            return (theInnerScope, ((bang_, argType) : argTypes))

        _ -> do
          let argType = toFreeFoilType SortBinder config outerScope outerScope rawArgType
          (theInnerScope, argTypes) <- goTypeArgs (i + 1) outerScope rawArgs
          return (theInnerScope, ((bang_, argType) : argTypes))

    go :: Con -> Q Con
    go = \case
      GadtC conNames argTypes retType -> do
        (theInnerScope, newArgs) <- goTypeArgs 0 theOuterScope argTypes
        let newConNames = map (toConName config) conNames
        forM_ (zip conNames newConNames) $ \(conName, newConName) ->
          addModFinalizer $ putDoc (DeclDoc newConName)
            ("Corresponds to '" ++ show conName ++ "'.")
        return (GadtC newConNames newArgs (goType theInnerScope retType))
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC params ctx con -> ForallC params ctx <$> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

termConToPat :: Name -> FreeFoilConfig -> FreeFoilTermConfig -> Con -> Q [([Name], Pat, Pat, [Exp])]
termConToPat rawTypeName config@FreeFoilConfig{..} FreeFoilTermConfig{..} = go
  where
    rawRetType = error "impossible happened!"

    fromArgType :: Type -> Q ([Name], [Pat], [Pat], [Exp])
    fromArgType = \case
      PeelConT typeName _params
        | Just _ <- lookupBindingName typeName freeFoilTermConfigs -> do
            return ([], [], [], [])
        | Just _ <- lookupScopeName typeName freeFoilTermConfigs -> do
            binder <- newName "binder"
            body <- newName "body"
            return ([binder, body], [ConP 'Foil.ScopedAST [] [VarP binder, VarP body]], [TupP [VarP binder, VarP body]], [VarE binder, VarE body])
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (VarE funName) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (VarE funName) (VarE x)])
        | typeName == '[] -> do
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [ConE 'False])
      AppT _ (PeelConT typeName _params)
        -- | Just _ <- lookupTermName typeName freeFoilTermConfigs -> do
        --     let funName = toFreeFoilNameFrom config typeName
        --     x <- newName "x"
        --     return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
      _ -> do
        x <- newName "x"
        return ([x], [VarP x], [VarP x], [VarE x])

    go :: Con -> Q [([Name], Pat, Pat, [Exp])]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        forM conNames $ \conName -> do
          let newConName = toSignatureName config conName
          (concat -> vars, concat -> pats, concat -> pats', concat -> exps) <- unzip4 <$>
            mapM (fromArgType . snd) rawArgTypes
          return $
            if rawTypeName == rawTermName
              then [ (vars, ConP 'Foil.Node [] [ConP newConName [] pats], ConP newConName [] pats', exps) ]
              else [ (vars, ConP newConName [] pats, ConP newConName [] pats', exps) ]
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

termConToPatBinding :: Name -> FreeFoilConfig -> FreeFoilTermConfig -> Con -> Q [([Name], Pat, Pat, [Exp])]
termConToPatBinding rawTypeName config@FreeFoilConfig{..} FreeFoilTermConfig{..} = go
  where
    rawRetType = error "impossible happened!"

    fromArgType :: Type -> Q ([Name], [Pat], [Pat], [Exp])
    fromArgType = \case
      PeelConT typeName _params
        | typeName == rawIdentName -> do
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [VarE intToRawIdentName `AppE` (VarE 'Foil.nameId `AppE` (VarE 'Foil.nameOf `AppE` VarE x))])
        | Just _ <- lookupBindingName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameFrom config typeName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [VarE funName `AppE` VarE x])
        | Just _ <- lookupScopeName typeName freeFoilTermConfigs -> do
            binder <- newName "binder"
            body <- newName "body"
            return ([binder, body], [ConP 'Foil.ScopedAST [] [VarP binder, VarP body]], [TupP [VarP binder, VarP body]], [VarE binder, VarE body])
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (VarE funName) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (VarE funName) (VarE x)])
      AppT _ (PeelConT typeName _params)
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
      _ -> do
        x <- newName "x"
        return ([x], [VarP x], [VarP x], [VarE x])

    go :: Con -> Q [([Name], Pat, Pat, [Exp])]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        forM conNames $ \conName -> do
          let newConName = toFreeFoilName config conName
          (concat -> vars, concat -> pats, concat -> pats', concat -> exps) <- unzip4 <$>
            mapM (fromArgType . snd) rawArgTypes
          return $
            if rawTypeName == rawTermName
              then [ (vars, ConP 'Foil.Node [] [ConP newConName [] pats], ConP newConName [] pats', exps) ]
              else [ (vars, ConP newConName [] pats, ConP newConName [] pats', exps) ]
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

termConToPatQuantified :: FreeFoilConfig -> Con -> Q [([Name], Pat, Pat, [Exp])]
termConToPatQuantified config@FreeFoilConfig{..} = go
  where
    rawRetType = error "impossible happened!"

    fromArgType :: Type -> Q ([Name], [Pat], [Pat], [Exp])
    fromArgType = \case
      PeelConT typeName _params
        | Just _ <- lookupTermName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameFrom config typeName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [VarE funName `AppE` VarE x])
        | Just FreeFoilTermConfig{..} <- lookupScopeName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameFrom config rawTermName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [VarE rawTermToScopeName `AppE` (VarE funName `AppE` VarE x)])
        | Just FreeFoilTermConfig{..} <- lookupIdentName typeName freeFoilTermConfigs -> do
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [VarE intToRawIdentName `AppE` (VarE 'Foil.nameId `AppE` VarE x)])
        | Just _ <- lookupBindingName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameFrom config typeName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [VarE funName `AppE` VarE x])
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (VarE funName) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameFrom config rawSigName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (VarE funName) (VarE x)])
      AppT _ (PeelConT typeName _params)
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameFrom config typeName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameFrom config typeName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
        | Just _ <- lookupTermName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameFrom config typeName
            x <- newName "x"
            return ([x], [VarP x], [VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
      _ -> do
        x <- newName "x"
        return ([x], [VarP x], [VarP x], [VarE x])

    go :: Con -> Q [([Name], Pat, Pat, [Exp])]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        forM conNames $ \conName -> do
          let newConName = toFreeFoilName config conName
          (concat -> vars, concat -> pats, concat -> pats', concat -> exps) <- unzip4 <$>
            mapM (fromArgType . snd) rawArgTypes
          return [ (vars, ConP newConName [] pats, ConP newConName [] pats', exps) ]
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

mkPatternSynonym :: Name -> FreeFoilConfig -> FreeFoilTermConfig -> Type -> Con -> Q [(Name, [Dec])]
mkPatternSynonym rawTypeName config termConfig@FreeFoilTermConfig{..} rawRetType = go
  where
    go :: Con -> Q [(Name, [Dec])]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        forM (conNames \\ [rawVarConName]) $ \conName -> do
          let patName = toConName config conName
              rawConType = foldr (\x y -> AppT (AppT ArrowT x) y) rawRetType (map snd rawArgTypes)
              outerScope = VarT (mkName "o")
              innerScope
                | rawTypeName `elem` rawSubScopeNames = outerScope
                | otherwise = VarT (mkName "i")
          [(vars, pat, _, _)] <- termConToPat rawTypeName config termConfig (GadtC [conName] rawArgTypes rawRetType)    -- FIXME: unsafe matching!
          addModFinalizer $ putDoc (DeclDoc patName)
            ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Pattern synonym for an '" ++ show ''Foil.AST ++ "' node of type '" ++ show conName ++ "'.")
          return [(patName,
            [ PatSynSigD patName (toFreeFoilType SortTerm config outerScope innerScope rawConType)
            , PatSynD patName (PrefixPatSyn vars) ImplBidir pat
            ])]

      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con  -- FIXME: params and ctx!
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

toFreeFoilClauseFrom :: Name -> FreeFoilConfig -> FreeFoilTermConfig -> Type -> Con -> Q [Clause]
toFreeFoilClauseFrom rawTypeName config termConfig@FreeFoilTermConfig{..} rawRetType = go
  where
    go = \case
      GadtC conNames rawArgTypes rawRetType' -> concat <$> do
        forM (conNames \\ [rawVarConName]) $ \conName -> do
          [(_vars, _pat, pat, exps)] <- termConToPat rawTypeName config termConfig
            (GadtC [conName] rawArgTypes rawRetType')    -- FIXME: unsafe matching!
          return [ Clause [pat] (NormalB (foldl AppE (ConE conName) exps)) [] ]

      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

toFreeFoilClauseFromBinding :: FreeFoilConfig -> FreeFoilTermConfig -> Type -> Con -> Q [Clause]
toFreeFoilClauseFromBinding config termConfig@FreeFoilTermConfig{..} rawRetType = go
  where
    go = \case
      GadtC conNames rawArgTypes rawRetType' -> concat <$> do
        forM (conNames \\ [rawVarConName]) $ \conName -> do
          [(_vars, _pat, pat, exps)] <- termConToPatBinding rawBindingName config termConfig
            (GadtC [conName] rawArgTypes rawRetType')    -- FIXME: unsafe matching!
          return [ Clause [pat] (NormalB (foldl AppE (ConE conName) exps)) [] ]

      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

toFreeFoilClauseFromQuantified :: FreeFoilConfig -> Type -> Con -> Q [Clause]
toFreeFoilClauseFromQuantified config rawRetType = go
  where
    go = \case
      GadtC conNames rawArgTypes rawRetType' -> concat <$> do
        forM conNames $ \conName -> do
          [(_vars, _pat, pat, exps)] <- termConToPatQuantified config
            (GadtC [conName] rawArgTypes rawRetType')    -- FIXME: unsafe matching!
          return [ Clause [pat] (NormalB (foldl AppE (ConE conName) exps)) [] ]

      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

-- | Generate scope-safe types and pattern synonyms for a given raw set of types:
--
--  1. Scope-safe quantified types (e.g. type schemas, defining equations of functions, unification constraints, data/type declarations)
--  2. Scope-safe terms, scoped terms, subterms, scoped subterms.
--  3. Scope-safe patterns.
--  4. Signatures for terms, subterms, and scoped subterms.
--  5. Pattern synonyms for terms, subterms, and scoped subterms.
mkFreeFoil :: FreeFoilConfig -> Q [Dec]
mkFreeFoil config@FreeFoilConfig{..} = concat <$> sequence
  [ mapM mkQuantifiedType rawQuantifiedNames
  , mapM mkBindingType freeFoilTermConfigs
  , concat <$> mapM mkSignatureTypes freeFoilTermConfigs
  , concat <$> mapM mkPatternSynonyms freeFoilTermConfigs
  ]
  where
    scope = mkName "scope"
    term = mkName "term"
    outerScope = mkName "o"
    innerScope = mkName "i"

    mkPatternSynonyms termConfig@FreeFoilTermConfig{..} = do
      ds <- mkPatternSynonyms' termConfig rawTermName
      ds' <- concat <$> mapM (mkPatternSynonyms' termConfig) (rawSubTermNames <> rawSubScopeNames)
      return (ds <> ds')

    mkPatternSynonyms' FreeFoilTermConfig{..} rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      let rawRetType = PeelConT rawName (map (VarT . tvarName) tvars)
      (unzip -> (patNames, decls)) <- concat <$> mapM (mkPatternSynonym rawName config FreeFoilTermConfig{..} rawRetType) cons
      let completeDecl
            | rawName == rawTermName = PragmaD (CompleteP ('Foil.Var : patNames) Nothing)
            | otherwise = PragmaD (CompleteP patNames Nothing)
      return (concat decls ++ [completeDecl])

    mkQuantifiedType rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      let name = toFreeFoilName config rawName
          rawRetType = PeelConT rawName (map (VarT . tvarName) tvars)
          newParams = tvars ++ [PlainTV outerScope BndrReq]
          toCon = toFreeFoilCon config rawRetType (VarT outerScope) (VarT innerScope)
      newCons <- mapM toCon cons
      addModFinalizer $ putDoc (DeclDoc name)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. A scope-safe version of '" ++ show rawName ++ "'.")
      return (DataD [] name newParams Nothing newCons [])

    mkBindingType FreeFoilTermConfig{..} = do
      (tvars, cons) <- reifyDataOrNewtype rawBindingName
      let bindingName = toFreeFoilName config rawBindingName
          rawRetType = PeelConT rawBindingName (map (VarT . tvarName) tvars)
          newParams = tvars ++ [PlainTV outerScope BndrReq, PlainTV innerScope BndrReq]
          toCon = toFreeFoilBindingCon config rawRetType (VarT outerScope)
      newCons <- mapM toCon cons
      addModFinalizer $ putDoc (DeclDoc bindingName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. A binding type, scope-safe version of '" ++ show rawBindingName ++ "'.")
      return (DataD [] bindingName newParams Nothing newCons [])

    mkSignatureTypes termConfig@FreeFoilTermConfig{..} = do
      sig <- mkSignatureType termConfig rawTermName
      subsigs <- concat <$> mapM (mkSignatureType termConfig) (rawSubTermNames <> rawSubScopeNames)
      return (sig ++ subsigs)

    mkSignatureType termConfig@FreeFoilTermConfig{..} rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      let sigName = toSignatureName config rawName
          tvars' = map (VarT . tvarName) tvars
          rawRetType = PeelConT rawName tvars'
          newParams = tvars ++ [PlainTV scope BndrReq, PlainTV term BndrReq]
          toCon = toFreeFoilSigCon config termConfig sigName rawRetType (VarT scope) (VarT term)
      newCons <- catMaybes <$> mapM toCon cons
      let bindingT = PeelConT (toFreeFoilName config rawBindingName) tvars'
          sigNameT = PeelConT (toSignatureName config rawTermName) tvars'
          astName = toFreeFoilName config rawName
          scopeName = toFreeFoilScopedName config rawName
          termAST = PeelConT ''Foil.AST [bindingT, sigNameT]
          scopedTermAST = PeelConT ''Foil.ScopedAST [bindingT, sigNameT]
          n = mkName "n"
      addModFinalizer $ putDoc (DeclDoc sigName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. A signature based on '" ++ show rawName ++ "'.")
      addModFinalizer $ putDoc (DeclDoc astName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. A scope-safe version of '" ++ show rawName ++ "'.")
      when (rawTermName == rawName) $ do
        addModFinalizer $ putDoc (DeclDoc scopeName)
          ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. A scoped (and scope-safe) version of '" ++ show rawName ++ "'.")
      return $ concat
        [ [ DataD [] sigName newParams Nothing newCons [DerivClause Nothing [ConT ''GHC.Generic, ConT ''Functor, ConT ''Foldable, ConT ''Traversable]] ]
        , if rawTermName == rawName
            then [ TySynD astName   tvars termAST
                 , TySynD scopeName tvars scopedTermAST ]
            else [ TySynD astName   (tvars ++ [PlainTV n BndrReq])
                    (PeelConT sigName
                      (tvars' ++
                      [ AppT scopedTermAST (VarT n)
                      , AppT termAST (VarT n) ])) ]
        ]

infixr 3 -->
(-->) :: Type -> Type -> Type
a --> b = AppT (AppT ArrowT a) b

reifyDataOrNewtype :: Name -> Q ([TyVarBndr BndrVis], [Con])
reifyDataOrNewtype name = reify name >>= \case
  TyConI (DataD _ctx _name tvars _kind cons _deriv) -> return (tvars, cons)
  TyConI (NewtypeD _ctx _name tvars _kind con _deriv) -> return (tvars, [con])
  _ -> error ("not a data or newtype: " ++ show name)

-- | Generate conversions to and from scope-safe representation:
--
--  1. Conversions for scope-safe quantified types (e.g. type schemas, defining equations of functions, unification constraints, data/type declarations)
--  2. Conversions for scope-safe terms, scoped terms, subterms, scoped subterms.
--  3. CPS-style conversions for scope-safe patterns.
--  4. Helpers for signatures of terms, subterms, and scoped subterms.
mkFreeFoilConversions :: FreeFoilConfig -> Q [Dec]
mkFreeFoilConversions config@FreeFoilConfig{..} = concat <$> sequence
  [ concat <$> mapM mkConvertFrom freeFoilTermConfigs
  , concat <$> mapM mkConvertFromQuantified rawQuantifiedNames
  , concat <$> mapM mkConvertTo freeFoilTermConfigs
  , concat <$> mapM mkConvertToQuantified rawQuantifiedNames
  ]
  where
    outerScope = mkName "o"
    innerScope = mkName "i"

    mkConvertFrom termConfig@FreeFoilTermConfig{..} = concat <$> sequence
      [ concat <$> mapM (mkConvertFromSig termConfig) (rawTermName : (rawSubTermNames <> rawSubScopeNames))
      , mkConvertFromBinding termConfig
      , concat <$> mapM (mkConvertFromSubTerm termConfig) (rawSubTermNames <> rawSubScopeNames)
      , mkConvertFromTerm termConfig
      ]

    mkConvertFromSig termConfig@FreeFoilTermConfig{..} rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      let rawSigName = toSignatureName config rawName
          funName = toFreeFoilNameFrom config rawSigName
          rawRetType = PeelConT rawName (map (VarT . tvarName) tvars)
          rawTermType = PeelConT rawTermName (map (VarT . tvarName) tvars)
          rawScopedTermType = PeelConT rawScopeName (map (VarT . tvarName) tvars)
          rawBindingType = PeelConT rawBindingName (map (VarT . tvarName) tvars)
          rawScopeType = TupleT 2 `AppT` rawBindingType `AppT` rawScopedTermType
      case toFreeFoilSigType SortSubTerm config rawScopeType rawTermType rawRetType of
        Just termType -> do
          clauses <- concat <$> mapM (toFreeFoilClauseFrom rawSigName config termConfig rawRetType) cons
          addModFinalizer $ putDoc (DeclDoc funName)
            ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. A helper used to convert from scope-safe to raw representation.")
          return
            [ SigD funName (AppT (AppT ArrowT termType) rawRetType)
            , FunD funName clauses ]
        Nothing -> error "impossible happened"

    mkConvertFromTerm FreeFoilTermConfig{..} = do
      (tvars, _cons) <- reifyDataOrNewtype rawTermName
      let funName = toFreeFoilNameFrom config rawTermName
          rawSigName = toSignatureName config rawTermName
          funSigName = toFreeFoilNameFrom config rawSigName
          funBindingName = toFreeFoilNameFrom config rawBindingName
          rawTermType = PeelConT rawTermName (map (VarT . tvarName) tvars)
          termType =  toFreeFoilType SortTerm config (VarT outerScope) (VarT innerScope) rawTermType
      addModFinalizer $ putDoc (DeclDoc funName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert from scope-safe to raw representation.")
      return
        [ SigD funName (AppT (AppT ArrowT termType) rawTermType)
        , FunD funName [
            Clause [] (NormalB
              (VarE 'Foil.convertFromAST
                `AppE` VarE funSigName
                `AppE` VarE rawVarIdentToTermName
                `AppE` VarE funBindingName
                `AppE` VarE rawTermToScopeName
                `AppE` VarE intToRawIdentName)) []
          ]
        ]

    mkConvertFromSubTerm FreeFoilTermConfig{..} rawName = do
      (tvars, _cons) <- reifyDataOrNewtype rawName
      let funName = toFreeFoilNameFrom config rawName
          funSigName = toFreeFoilNameFrom config (toSignatureName config rawName)
          funTermName = toFreeFoilNameFrom config rawTermName
          funBindingName = toFreeFoilNameFrom config rawBindingName
          rawType = PeelConT rawName (map (VarT . tvarName) tvars)
          safeType =  toFreeFoilType SortTerm config (VarT outerScope) (VarT innerScope) rawType
      binders <- newName "binders"
      body <- newName "body"
      addModFinalizer $ putDoc (DeclDoc funName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert from scope-safe to raw representation.")
      return
        [ SigD funName (AppT (AppT ArrowT safeType) rawType)
        , FunD funName [
            Clause [] (NormalB $
              InfixE
              (Just (VarE funSigName))
              (VarE '(.))
              (Just (VarE 'bimap
                `AppE` LamE [ConP 'Foil.ScopedAST [] [VarP binders, VarP body]]
                  (TupE [ Just (VarE funBindingName `AppE` VarE binders)
                        , Just (VarE rawTermToScopeName `AppE` (VarE funTermName `AppE` VarE body))])
                `AppE` VarE funTermName))) []
          ]
        ]

    mkConvertFromQuantified rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      let funName = toFreeFoilNameFrom config rawName
          rawType = PeelConT rawName (map (VarT . tvarName) tvars)
          safeType = toFreeFoilType SortTerm config (VarT outerScope) (VarT innerScope) rawType
      addModFinalizer $ putDoc (DeclDoc funName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert from scope-safe to raw representation.")
      clauses <- concat <$> mapM (toFreeFoilClauseFromQuantified config rawType) cons
      return
        [ SigD funName (AppT (AppT ArrowT safeType) rawType)
        , FunD funName clauses
        ]

    mkConvertFromBinding termConfig@FreeFoilTermConfig{..} = do
      (tvars, cons) <- reifyDataOrNewtype rawBindingName
      let funName = toFreeFoilNameFrom config rawBindingName
          rawRetType = PeelConT rawBindingName (map (VarT . tvarName) tvars)
          bindingType = toFreeFoilType SortBinder config (VarT outerScope) (VarT innerScope) rawRetType
      clauses <- concat <$> mapM (toFreeFoilClauseFromBinding config termConfig rawRetType) cons
      addModFinalizer $ putDoc (DeclDoc funName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert a scope-safe to a raw binding.")
      return
        [ SigD funName (bindingType --> rawRetType)
        , FunD funName clauses ]

    mkConvertTo termConfig@FreeFoilTermConfig{..} = concat <$> sequence
      [ mkConvertToSig SortTerm termConfig rawTermName
      , concat <$> mapM (mkConvertToSig SortSubTerm termConfig) (rawSubTermNames <> rawSubScopeNames)
      , mkConvertToBinding termConfig
      , concat <$> mapM (mkConvertToSubTerm termConfig) (rawSubTermNames <> rawSubScopeNames)
      , mkConvertToTerm termConfig
      ]

    mkConvertToSubTerm termConfig@FreeFoilTermConfig{..} rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      (itvars, _cons) <- reifyDataOrNewtype rawIdentName
      let funName = toFreeFoilNameTo config rawName
          rawIdentType = PeelConT rawIdentName (map (VarT . tvarName) (take (length itvars) tvars)) -- FIXME: undocumented hack :(
          rawType = PeelConT rawName (map (VarT . tvarName) tvars)
          safeType =  toFreeFoilType SortTerm config (VarT outerScope) (VarT innerScope) rawType
      clauses <- concat <$> mapM (subTermConToClause rawType config termConfig) cons
      addModFinalizer $ putDoc (DeclDoc funName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert from scope-safe to raw representation.")
      let scope
            | rawName `elem` rawSubTermNames = outerScope
            | otherwise = innerScope
      return
        [ SigD funName $
            ForallT
              (PlainTV scope SpecifiedSpec : map (SpecifiedSpec <$) tvars)
              [ ConT ''Foil.Distinct `AppT` VarT scope
              , ConT ''Ord `AppT` rawIdentType ] $
                (ConT ''Foil.Scope `AppT` VarT scope)
                --> (ConT ''Map `AppT` rawIdentType `AppT` (ConT ''Foil.Name `AppT` VarT scope))
                --> rawType
                --> safeType
        , FunD funName clauses
        ]

    mkConvertToTerm FreeFoilTermConfig{..} = do
      (tvars, _cons) <- reifyDataOrNewtype rawTermName
      (itvars, _cons) <- reifyDataOrNewtype rawIdentName
      let funName = toFreeFoilNameTo config rawTermName
          rawSigName = toSignatureName config rawTermName
          rawIdentType = PeelConT rawIdentName (map (VarT . tvarName) (take (length itvars) tvars)) -- FIXME: undocumented hack :(
          funSigName = toFreeFoilNameTo config rawSigName
          funBindingName = toFreeFoilNameTo config rawBindingName
          rawTermType = PeelConT rawTermName (map (VarT . tvarName) tvars)
          termType =  toFreeFoilType SortTerm config (VarT outerScope) (VarT innerScope) rawTermType
      addModFinalizer $ putDoc (DeclDoc funName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert from scope-safe to raw representation.")
      return
        [ SigD funName $
            ForallT
              (PlainTV outerScope SpecifiedSpec : map (SpecifiedSpec <$) tvars)
              [ ConT ''Foil.Distinct `AppT` VarT outerScope
              , ConT ''Ord `AppT` rawIdentType ] $
                (ConT ''Foil.Scope `AppT` VarT outerScope)
                --> (ConT ''Map `AppT` rawIdentType `AppT` (ConT ''Foil.Name `AppT` VarT outerScope))
                --> rawTermType
                --> termType
        , FunD funName [
            Clause [] (NormalB
              (VarE 'Foil.convertToAST
                `AppE` VarE funSigName
                `AppE` VarE funBindingName
                `AppE` VarE rawScopeToTermName)) []
          ]
        ]

    mkConvertToSig sort termConfig@FreeFoilTermConfig{..} rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      (itvars, _cons) <- reifyDataOrNewtype rawIdentName
      let rawSigName = toSignatureName config rawName
          funName = toFreeFoilNameTo config rawSigName
          rawType = PeelConT rawName (map (VarT . tvarName) tvars)
          rawIdentType = PeelConT rawIdentName (map (VarT . tvarName) (take (length itvars) tvars)) -- FIXME: undocumented hack :(
          rawTermType = PeelConT rawTermName (map (VarT . tvarName) tvars)
          rawScopedTermType = PeelConT rawScopeName (map (VarT . tvarName) tvars)
          rawBindingType = PeelConT rawBindingName (map (VarT . tvarName) tvars)
          rawScopeType = TupleT 2 `AppT` rawBindingType `AppT` rawScopedTermType
      case toFreeFoilSigType SortSubTerm config rawScopeType rawTermType rawType of
        Just safeType -> do
          let retType = case sort of
                SortTerm -> ConT ''Either `AppT` rawIdentType `AppT` safeType
                _        -> safeType
          clauses <- concat <$> mapM (sigConToClause sort rawType config termConfig) cons
          addModFinalizer $ putDoc (DeclDoc funName)
            ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. A helper used to convert from raw to scope-safe representation.")
          return
            [ SigD funName (AppT (AppT ArrowT rawType) retType)
            , FunD funName clauses ]
        Nothing -> error "impossible happened"

    mkConvertToBinding termConfig@FreeFoilTermConfig{..} = do
      (tvars, cons) <- reifyDataOrNewtype rawBindingName
      (itvars, _cons) <- reifyDataOrNewtype rawIdentName
      let funName = toFreeFoilNameTo config rawBindingName
          rawBindingType = PeelConT rawBindingName (map (VarT . tvarName) tvars)
          rawIdentType = PeelConT rawIdentName (map (VarT . tvarName) (take (length itvars) tvars)) -- FIXME: undocumented hack :(
          safeType = toFreeFoilType SortBinder config (VarT outerScope) (VarT innerScope) rawBindingType
      clauses <- concat <$> mapM (bindingConToClause rawBindingType config termConfig) cons
      r <- newName "r"
      addModFinalizer $ putDoc (DeclDoc funName)
        ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert from raw to scope-safe binding (CPS-style).")
      return
        [ SigD funName $
            ForallT
              (PlainTV outerScope SpecifiedSpec : map (SpecifiedSpec <$) tvars ++ [PlainTV r SpecifiedSpec])
              [ ConT ''Foil.Distinct `AppT` VarT outerScope
              , ConT ''Ord `AppT` rawIdentType ] $
                (ConT ''Foil.Scope `AppT` VarT outerScope)
                --> (ConT ''Map `AppT` rawIdentType `AppT` (ConT ''Foil.Name `AppT` VarT outerScope))
                --> rawBindingType
                --> ForallT [PlainTV innerScope SpecifiedSpec]
                      [ConT ''Foil.DExt `AppT` VarT outerScope `AppT` VarT innerScope]
                      (safeType
                        --> (ConT ''Map `AppT` rawIdentType `AppT` (ConT ''Foil.Name `AppT` VarT innerScope))
                        --> VarT r)
                --> VarT r
        , FunD funName clauses ]

    mkConvertToQuantified rawName = do
      (tvars, cons) <- reifyDataOrNewtype rawName
      rawIdentNamesOfQuantifiedName rawName config >>= \case
        [] -> error "unexpected: quantified type not connected to any known terms"
        [rawIdentName'] -> do
          (itvars, _cons) <- reifyDataOrNewtype rawIdentName'
          let funName = toFreeFoilNameTo config rawName
              rawIdentType = PeelConT rawIdentName' (map (VarT . tvarName) (take (length itvars) tvars)) -- FIXME: undocumented hack :(
              rawType = PeelConT rawName (map (VarT . tvarName) tvars)
              safeType = toFreeFoilType SortTerm config (VarT outerScope) (VarT innerScope) rawType
          addModFinalizer $ putDoc (DeclDoc funName)
            ("/Generated/ with '" ++ show 'mkFreeFoil ++ "'. Convert from scope-safe to raw representation.")
          clauses <- concat <$> mapM (quantifiedConToClause rawType config) cons
          return
            [ SigD funName $
                ForallT
                  (PlainTV outerScope SpecifiedSpec : map (SpecifiedSpec <$) tvars)
                  [ ConT ''Foil.Distinct `AppT` VarT outerScope
                  , ConT ''Ord `AppT` rawIdentType ] $
                    (ConT ''Foil.Scope `AppT` VarT outerScope)
                    --> (ConT ''Map `AppT` rawIdentType `AppT` (ConT ''Foil.Name `AppT` VarT outerScope))
                    --> rawType
                    --> safeType
            , FunD funName clauses
            ]
        _ -> do
          -- error ("unsupported: more than one known term connected to the quantified type: " <> show rawName)
          return []

quantifiedConToClause :: Type -> FreeFoilConfig -> Con -> Q [Clause]
quantifiedConToClause rawType config@FreeFoilConfig{..} = go
  where
    goArgTypes :: Name -> Name -> Name -> Name -> [Type] -> Q ([Pat], [Exp], Exp -> Exp, Name, Name)
    goArgTypes _theScope _theEnv scope env [] = return ([], [], id, scope, env)
    goArgTypes theScope theEnv scope env (t:ts) = case t of
      PeelConT typeName _params
        | typeName `elem` map rawIdentName freeFoilTermConfigs -> do
            x <- newName "_x"
            (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
            return (VarP x : pats, (InfixE (Just (VarE env)) (VarE '(Map.!)) (Just (VarE x))) : exps, wrap, scope', env')
        | Just _ <- lookupBindingName typeName freeFoilTermConfigs -> do
            x <- newName "_x"
            x' <- newName "_x'"
            scope' <- newName "_scope"
            env' <- newName "_env"
            let funName = toFreeFoilNameTo config typeName
            (pats, exps, wrap, scope'', env'') <- goArgTypes theScope theEnv scope' env' ts
            return (VarP x : pats, VarE x' : exps, \e ->
              VarE funName `AppE` VarE scope `AppE` VarE env `AppE` VarE x `AppE`
                LamE [VarP x', VarP env']
                  (LetE [ ValD (VarP scope') (NormalB (VarE 'Foil.extendScopePattern `AppE` VarE x' `AppE` VarE scope)) []]
                    (wrap e)), scope'', env'')
        | Just FreeFoilTermConfig{..} <- lookupScopeName typeName freeFoilTermConfigs -> do
            x <- newName "_x"
            let funName = toFreeFoilNameTo config rawTermName
            (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
            return (VarP x : pats,
              (VarE funName `AppE` VarE scope' `AppE` VarE env' `AppE` (VarE rawScopeToTermName `AppE` VarE x)) : exps,
              wrap, scope', env')
        | Just _ <- lookupTermName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameTo config typeName
            x <- newName "x"
            (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
            return (VarP x : pats, (VarE funName `AppE` VarE scope' `AppE` VarE env' `AppE` VarE x) : exps, wrap, scope', env')
      AppT _ (PeelConT typeName _params)
        | Just _ <- lookupTermName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameTo config typeName
            x <- newName "x"
            (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
            return (VarP x : pats, AppE (AppE (VarE 'fmap) (VarE funName `AppE` VarE theScope `AppE` VarE theEnv)) (VarE x) : exps, wrap, scope', env')
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameTo config typeName
            x <- newName "x"
            (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
            return (VarP x : pats, AppE (AppE (VarE 'fmap) (VarE funName `AppE` VarE theScope `AppE` VarE theEnv)) (VarE x) : exps, wrap, scope', env')
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameTo config typeName
            x <- newName "x"
            (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
            return (VarP x : pats, AppE (AppE (VarE 'fmap) (VarE funName `AppE` VarE scope' `AppE` VarE env')) (VarE x) : exps, wrap, scope', env')
        | Just FreeFoilTermConfig{..} <- lookupScopeName typeName freeFoilTermConfigs -> do
            let funName = toFreeFoilNameTo config rawTermName
            x <- newName "x"
            (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
            return (VarP x : pats, AppE (AppE (VarE 'fmap) (VarE funName `AppE` VarE scope' `AppE` VarE env')) (VarE x) : exps, wrap, scope', env')
      _ -> do
        x <- newName "_x"
        (pats, exps, wrap, scope', env') <- goArgTypes theScope theEnv scope env ts
        return (VarP x : pats, VarE x : exps, wrap, scope', env')

    go :: Con -> Q [Clause]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        scope <- newName "_scope"
        env <- newName "_env"
        forM conNames $ \conName -> do
          let newConName = toConName config conName
          (pats, exps, wrap, _scope', _env') <- goArgTypes scope env scope env (map snd rawArgTypes)
          return
            [ Clause [VarP scope, VarP env, ConP conName [] pats]
                (NormalB (wrap (foldl AppE (ConE newConName) exps))) [] ]
      NormalC conName types -> go (GadtC [conName] types rawType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

subTermConToClause :: Type -> FreeFoilConfig -> FreeFoilTermConfig -> Con -> Q [Clause]
subTermConToClause rawType config FreeFoilTermConfig{..} = go
  where
    goArgTypes :: Name -> Name -> [Type] -> Q ([Pat], [Exp], Exp -> Exp, Name, Name)
    goArgTypes scope env [] = return ([], [], id, scope, env)
    goArgTypes scope env (t:ts) = case t of
      PeelConT typeName _params
        | typeName == rawBindingName -> do
            x <- newName "_x"
            x' <- newName "_x'"
            scope' <- newName "_scope"
            env' <- newName "_env"
            let funName = toFreeFoilNameTo config typeName
            (pats, exps, wrap, scope'', env'') <- goArgTypes scope' env' ts
            return (VarP x : pats, VarE x' : exps, \e ->
              VarE funName `AppE` VarE scope `AppE` VarE env `AppE` VarE x `AppE`
                LamE [VarP x', VarP env']
                  (LetE [ ValD (VarP scope') (NormalB (VarE 'Foil.extendScopePattern `AppE` VarE x' `AppE` VarE scope)) []]
                    (wrap e)), scope'', env'')
        | typeName == rawScopeName -> do
            x <- newName "_x"
            let funName = toFreeFoilNameTo config rawTermName
            (pats, exps, wrap, scope', env') <- goArgTypes scope env ts
            return (VarP x : pats,
              (VarE funName `AppE` VarE scope' `AppE` VarE env' `AppE` (VarE rawScopeToTermName `AppE` VarE x)) : exps,
              wrap, scope', env')
        | typeName == rawTermName -> do
            x <- newName "_x"
            let funName = toFreeFoilNameTo config rawTermName
            (pats, exps, wrap, scope', env') <- goArgTypes scope env ts
            return (VarP x : pats,
              (VarE funName `AppE` VarE scope `AppE` VarE env `AppE` VarE x) : exps,
              wrap, scope', env')
        | typeName `elem` rawSubTermNames -> do
            x <- newName "_x"
            let funName = toFreeFoilNameTo config typeName
            (pats, exps, wrap, scope', env') <- goArgTypes scope env ts
            return (VarP x : pats,
              (VarE funName `AppE` VarE scope `AppE` VarE env `AppE` VarE x) : exps,
              wrap, scope', env')
      AppT _ (PeelConT typeName _params)
        | typeName == rawTermName -> do
            let funName = toFreeFoilNameTo config typeName
            x <- newName "_x"
            (pats, exps, wrap, scope', env') <- goArgTypes scope env ts
            return (VarP x : pats,
              (VarE 'fmap `AppE` (VarE funName `AppE` VarE scope `AppE` VarE env) `AppE` VarE x) : exps,
              wrap, scope', env')
        | typeName `elem` rawSubTermNames -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameTo config rawSigName
            x <- newName "_x"
            (pats, exps, wrap, scope', env') <- goArgTypes scope env ts
            return (VarP x : pats,
              (VarE 'fmap `AppE` (VarE funName `AppE` VarE scope `AppE` VarE env) `AppE` VarE x) : exps,
              wrap, scope', env')
        | typeName `elem` rawSubScopeNames -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameTo config rawSigName
            x <- newName "_x"
            (pats, exps, wrap, scope', env') <- goArgTypes scope env ts
            return (VarP x : pats,
              (VarE 'fmap `AppE` (VarE funName `AppE` VarE scope' `AppE` VarE env') `AppE` VarE x) : exps,
              wrap, scope', env')
      _ -> do
        x <- newName "_x"
        (pats, exps, wrap, scope', env') <- goArgTypes scope env ts
        return (VarP x : pats, VarE x : exps, wrap, scope', env')

    go :: Con -> Q [Clause]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        scope <- newName "_scope"
        env <- newName "_env"
        forM conNames $ \conName -> do
          let newConName = toConName config conName
          (pats, exps, wrap, _scope', _env') <- goArgTypes scope env (map snd rawArgTypes)
          return
            [ Clause [VarP scope, VarP env, ConP conName [] pats]
                (NormalB (wrap (foldl AppE (ConE newConName) exps))) [] ]
      NormalC conName types -> go (GadtC [conName] types rawType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

bindingConToClause :: Type -> FreeFoilConfig -> FreeFoilTermConfig -> Con -> Q [Clause]
bindingConToClause rawType config FreeFoilTermConfig{..} = go
  where
    goArgTypes :: Name -> Name -> [Type] -> Q ([Pat], [Exp], Exp -> Exp, Name)
    goArgTypes _scope env [] = return ([], [], id, env)
    goArgTypes scope env (t:ts) = case t of
      PeelConT typeName _params
        | typeName == rawIdentName -> do
            x <- newName "_x"
            x' <- newName "_x'"
            scope' <- newName "_scope"
            env' <- newName "_env"
            (pats, exps, wrap, env'') <- goArgTypes scope' env' ts
            return (VarP x : pats, VarE x' : exps, \e ->
              VarE 'Foil.withFresh `AppE` VarE scope `AppE`
                LamE [VarP x']
                  (LetE [ ValD (VarP scope') (NormalB (VarE 'Foil.extendScope `AppE` VarE x' `AppE` VarE scope)) []
                        , ValD (VarP env') (NormalB (VarE 'Map.insert `AppE` VarE x `AppE` (VarE 'Foil.nameOf `AppE` VarE x') `AppE` (VarE 'fmap `AppE` VarE 'Foil.sink `AppE` VarE env))) []]
                    (wrap e)), env'')
        | typeName == rawBindingName -> do
            x <- newName "_x"
            x' <- newName "_x'"
            scope' <- newName "_scope"
            env' <- newName "_env"
            let funName = toFreeFoilNameTo config typeName
            (pats, exps, wrap, env'') <- goArgTypes scope' env' ts
            return (VarP x : pats, VarE x' : exps, \e ->
              VarE funName `AppE` VarE scope `AppE` VarE env `AppE` VarE x `AppE`
                LamE [VarP x', VarP env']
                  (LetE [ ValD (VarP scope') (NormalB (VarE 'Foil.extendScopePattern `AppE` VarE x' `AppE` VarE scope)) []]
                    (wrap e)), env'')
      _ -> do
        x <- newName "_x"
        (pats, exps, wrap, env') <- goArgTypes scope env ts
        return (VarP x : pats, VarE x : exps, wrap, env')

    go :: Con -> Q [Clause]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        scope <- newName "_scope"
        env <- newName "_env"
        cont <- newName "_cont"
        forM conNames $ \conName -> do
          let newConName = toConName config conName
          (pats, exps, wrap, env') <- goArgTypes scope env (map snd rawArgTypes)
          return
            [ Clause [VarP scope, VarP env, ConP conName [] pats, VarP cont]
                (NormalB (wrap (VarE cont `AppE` foldl AppE (ConE newConName) exps `AppE` VarE env'))) [] ]
      NormalC conName types -> go (GadtC [conName] types rawType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)


sigConToClause :: Sort -> Type -> FreeFoilConfig -> FreeFoilTermConfig -> Con -> Q [Clause]
sigConToClause sort rawRetType config@FreeFoilConfig{..} FreeFoilTermConfig{..} = go
  where
    fromArgType :: Bool -> Name -> Type -> Q ([Pat], [Exp])
    fromArgType isVarCon theIdent = \case
      PeelConT typeName _params
        | typeName == rawIdentName, SortTerm <- sort, isVarCon -> do
            return ([VarP theIdent], [VarE theIdent])
        | Just _ <- lookupBindingName typeName freeFoilTermConfigs -> do
            return ([], [])
        | Just _ <- lookupScopeName typeName freeFoilTermConfigs -> do
            binder <- newName "binder"
            body <- newName "body"
            return ([VarP binder, VarP body], [TupE [Just (VarE binder), Just (VarE body)]])
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameTo config rawSigName
            x <- newName "_x"
            return ([VarP x], [AppE (VarE funName) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameTo config rawSigName
            x <- newName "_x"
            return ([VarP x], [AppE (VarE funName) (VarE x)])
      AppT _ (PeelConT typeName _params)
        | Just _ <- lookupSubTermName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameTo config rawSigName
            x <- newName "_x"
            return ([VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
        | Just _ <- lookupSubScopeName typeName freeFoilTermConfigs -> do
            let rawSigName = toSignatureName config typeName
                funName = toFreeFoilNameTo config rawSigName
            x <- newName "_x"
            return ([VarP x], [AppE (AppE (VarE 'fmap) (VarE funName)) (VarE x)])
      _ -> do
        x <- newName "_x"
        return ([VarP x], [VarE x])

    go :: Con -> Q [Clause]
    go = \case
      GadtC conNames rawArgTypes _rawRetType -> concat <$> do
        theIdent <- newName "_theRawIdent"
        forM conNames $ \conName -> do
          let newConName = toSignatureName config conName
              isVarCon = conName == rawVarConName
          (concat -> pats, concat -> exps) <- unzip <$>
            mapM (fromArgType isVarCon theIdent . snd) rawArgTypes
          case sort of
            SortTerm
              | isVarCon -> return
                  [ Clause [ConP conName [] pats] (NormalB (ConE 'Left `AppE` VarE theIdent)) [] ]  -- FIXME!
              | otherwise -> return
                  [ Clause [ConP conName [] pats] (NormalB (ConE 'Right `AppE` (foldl AppE (ConE newConName) exps))) [] ]
            _ -> return
              [ Clause [ConP conName [] pats] (NormalB (foldl AppE (ConE newConName) exps)) [] ]
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

rawIdentNamesOfQuantifiedName :: Name -> FreeFoilConfig -> Q [Name]
rawIdentNamesOfQuantifiedName rawName config = do
  (_tvars, cons) <- reifyDataOrNewtype rawName
  return (nub (concatMap go cons))
  where
    rawRetType = error "impossible happened!"

    go :: Con -> [Name]
    go = \case
      GadtC _conNames rawArgTypes _rawRetType ->
        concatMap (rawIdentNamesOfType config . snd) rawArgTypes
      NormalC conName types -> go (GadtC [conName] types rawRetType)
      RecC conName types -> go (NormalC conName (map removeName types))
      InfixC l conName r -> go (GadtC [conName] [l, r] rawRetType)
      ForallC _params _ctx con -> go con
      RecGadtC conNames argTypes retType -> go (GadtC conNames (map removeName argTypes) retType)

rawIdentNamesOfType :: FreeFoilConfig -> Type -> [Name]
rawIdentNamesOfType FreeFoilConfig{..} = go
  where
    go = \case
      PeelConT typeName _params
        | typeName `elem` rawQuantifiedNames -> []
        | typeName `elem` map rawIdentName freeFoilTermConfigs -> [typeName]
        | Just FreeFoilTermConfig{..} <- lookupTermName typeName freeFoilTermConfigs ->
            [rawIdentName]
        | Just FreeFoilTermConfig{..} <- lookupBindingName typeName freeFoilTermConfigs ->
            [rawIdentName]
        | Just FreeFoilTermConfig{..} <- lookupScopeName typeName freeFoilTermConfigs ->
            [rawIdentName]
        | Just FreeFoilTermConfig{..} <- lookupSubTermName typeName freeFoilTermConfigs ->
            [rawIdentName]
        | Just FreeFoilTermConfig{..} <- lookupSubScopeName typeName freeFoilTermConfigs ->
            [rawIdentName]
      ForallT _bndrs _ctx type_ -> go type_
      ForallVisT _bndrs type_ -> go type_
      AppT f x -> go f <> go x
      AppKindT f _k -> go f
      SigT t _k -> go t
      ConT{} -> []
      VarT{} -> []
      PromotedT{} -> []
      InfixT l _op r -> go l <> go r
      UInfixT l _op r -> go l <> go r
      PromotedInfixT l _op r -> go l <> go r
      PromotedUInfixT l _op r -> go l <> go r
      ParensT t -> go t
      TupleT{} -> []
      UnboxedTupleT{} -> []
      UnboxedSumT{} -> []
      ArrowT{} -> []
      MulArrowT{} -> []
      EqualityT{} -> []
      ListT{} -> []
      PromotedTupleT{} -> []
      PromotedNilT{} -> []
      PromotedConsT{} -> []
      StarT{} -> []
      ConstraintT{} -> []
      LitT{} -> []
      WildCardT{} -> []
      ImplicitParamT _s t -> go t
