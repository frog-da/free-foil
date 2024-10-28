{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE TypeFamilies         #-}
{-# LANGUAGE DeriveAnyClass        #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PolyKinds             #-}
{-# LANGUAGE QuantifiedConstraints #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE UndecidableInstances  #-}
-- | This module defines a variation of
-- free scoped (relative) monads relying on the foil for
-- the scope-safe efficient handling of the binders.
--
-- See description of the approach in [«Free Foil: Generating Efficient and Scope-Safe Abstract Syntax»](https://arxiv.org/abs/2405.16384).
module Control.Monad.Free.Foil where

import           Control.DeepSeq
import qualified Control.Monad.Foil.Internal as Foil
import qualified Control.Monad.Foil.Relative as Foil
import           Data.Bifoldable
import           Data.Bitraversable
import           Data.Bifunctor
import Data.ZipMatchK
import qualified Generics.Kind as Kind
import Generics.Kind (GenericK(..), Field, Exists, Var0, Var1, (:$:), Atom((:@:), Kon), (:+:), (:*:))
import           Data.Coerce                 (coerce)
import           Data.Map                    (Map)
import qualified Data.Map                    as Map
import           Data.Monoid                 (All (..))
import           GHC.Generics                (Generic)

-- | Scoped term under a (single) name binder.
data ScopedAST binder sig n where
  ScopedAST :: binder n l -> AST binder sig l -> ScopedAST binder sig n

instance (forall x y. NFData (binder x y), forall l. NFData (AST binder sig l)) => NFData (ScopedAST binder sig n) where
  rnf (ScopedAST binder body) = rnf binder `seq` rnf body

-- | A term, generated by a signature 'Bifunctor' @sig@,
-- with (free) variables in scope @n@.
data AST binder sig n where
  -- | A (free) variable in scope @n@.
  Var :: Foil.Name n -> AST binder sig n
  -- | A non-variable syntactic construction specified by the signature 'Bifunctor' @sig@.
  Node :: sig (ScopedAST binder sig n) (AST binder sig n) -> AST binder sig n

deriving instance Generic (AST binder sig n)
deriving instance (forall x y. NFData (binder x y), forall scope term. (NFData scope, NFData term) => NFData (sig scope term))
  => NFData (AST binder sig n)

instance GenericK (ScopedAST binder sig) where
  type RepK (ScopedAST binder sig) =
    Exists Foil.S
      (Field (Kon binder :@: Var1 :@: Var0) :*: Field (Kon AST :@: Kon binder :@: Kon sig :@: Var0))
  toK (Kind.Exists (Kind.Field binder Kind.:*: Kind.Field ast)) = ScopedAST binder ast
  fromK (ScopedAST binder ast) = Kind.Exists (Kind.Field binder Kind.:*: Kind.Field ast)

instance GenericK (AST binder sig) where
  type RepK (AST binder sig) =
    Field (Foil.Name :$: Var0)
    :+: Field (sig
                :$: (Kon ScopedAST :@: Kon binder :@: Kon sig :@: Var0)
                :@: (Kon AST :@: Kon binder :@: Kon sig :@: Var0))

instance (Bifunctor sig, Foil.CoSinkable binder) => Foil.Sinkable (ScopedAST binder sig)
instance (Bifunctor sig, Foil.CoSinkable binder) => Foil.Sinkable (AST binder sig)

instance (Bifunctor sig, Foil.CoSinkable binder) => Foil.SinkableK (ScopedAST binder sig)
instance (Bifunctor sig, Foil.CoSinkable binder) => Foil.SinkableK (AST binder sig)

instance Foil.InjectName (AST binder sig) where
  injectName = Var

-- * Substitution

-- | Substitution for free (scoped monads).
substitute
  :: (Bifunctor sig, Foil.Distinct o, Foil.CoSinkable binder)
  => Foil.Scope o
  -> Foil.Substitution (AST binder sig) i o
  -> AST binder sig i
  -> AST binder sig o
substitute scope subst = \case
  Var name -> Foil.lookupSubst subst name
  Node node -> Node (bimap f (substitute scope subst) node)
  where
    f (ScopedAST binder body) =
      Foil.withRefreshedPattern scope binder $ \extendSubst binder' ->
        let subst' = extendSubst (Foil.sink subst)
            scope' = Foil.extendScopePattern binder' scope
            body' = substitute scope' subst' body
        in ScopedAST binder' body'

-- | Substitution for free (scoped monads).
--
-- This is a version of 'substitute' that forces refreshing of all name binders,
-- resulting in a term with normalized binders:
--
-- > substituteRefreshed scope subst = refreshAST scope . subtitute scope subst
--
-- In general, 'substitute' is more efficient since it does not always refresh binders.
substituteRefreshed
  :: (Bifunctor sig, Foil.Distinct o, Foil.CoSinkable binder)
  => Foil.Scope o
  -> Foil.Substitution (AST binder sig) i o
  -> AST binder sig i
  -> AST binder sig o
substituteRefreshed scope subst = \case
  Var name -> Foil.lookupSubst subst name
  Node node -> Node (bimap f (substituteRefreshed scope subst) node)
  where
    f (ScopedAST binder body) =
      Foil.withFreshPattern scope binder $ \extendSubst binder' ->
        let subst' = extendSubst (Foil.sink subst)
            scope' = Foil.extendScopePattern binder' scope
            body' = substituteRefreshed scope' subst' body
        in ScopedAST binder' body'

-- | @'AST' sig@ is a monad relative to 'Foil.Name'.
instance (Bifunctor sig, Foil.CoSinkable binder) => Foil.RelMonad Foil.Name (AST binder sig) where
  rreturn = Var
  rbind scope term subst =
    case term of
      Var name  -> subst name
      Node node -> Node (bimap g' g node)
    where
      g x = Foil.rbind scope x subst
      g' (ScopedAST binder body) =
        Foil.withRefreshedPattern' scope binder $ \extendSubst binder' ->
          let scope' = Foil.extendScopePattern binder' scope
              subst' = extendSubst subst
           in ScopedAST binder' (Foil.rbind scope' body subst')

-- | Substitution for a single generalized pattern.
substitutePattern
  :: (Bifunctor sig, Foil.Distinct o, Foil.CoSinkable binder', Foil.CoSinkable binder)
  => Foil.Scope o                           -- ^ Resulting scope.
  -> Foil.Substitution (AST binder sig) n o -- ^ Environment mapping names in scope @n@.
  -> binder' n i                            -- ^ Binders that extend scope @n@ to scope @i@.
  -> [AST binder sig o]                     -- ^ A list of terms intended to serve as
  -> AST binder sig i
  -> AST binder sig o
substitutePattern scope env binders args body =
  substitute scope env' body
  where
    env' = Foil.addSubstPattern env binders args

-- * \(\alpha\)-equivalence

-- | Refresh (force) all binders in a term, minimizing the used indices.
refreshAST
  :: (Bifunctor sig, Foil.Distinct n, Foil.CoSinkable binder)
  => Foil.Scope n
  -> AST binder sig n
  -> AST binder sig n
refreshAST scope = \case
  t@Var{} -> t
  Node t -> Node (bimap (refreshScopedAST scope) (refreshAST scope) t)

-- | Similar to `refreshAST`, but for scoped terms.
refreshScopedAST :: (Bifunctor sig, Foil.Distinct n, Foil.CoSinkable binder)
  => Foil.Scope n
  -> ScopedAST binder sig n
  -> ScopedAST binder sig n
refreshScopedAST scope (ScopedAST binder body) =
  Foil.withFreshPattern scope binder $ \extendSubst binder' ->
    let scope' = Foil.extendScopePattern binder' scope
        subst = extendSubst (Foil.sink Foil.identitySubst)
    in ScopedAST binder' (substituteRefreshed scope' subst body)

-- | \(\alpha\)-equivalence check for two terms in one scope
-- via normalization of bound identifiers (via 'refreshAST').
--
-- Compared to 'alphaEquiv', this function may perform some unnecessary
-- changes of bound variables when the binders are the same on both sides.
alphaEquivRefreshed
  :: (Bitraversable sig, ZipMatchK sig, Foil.Distinct n, Foil.UnifiablePattern binder)
  => Foil.Scope n
  -> AST binder sig n
  -> AST binder sig n
  -> Bool
alphaEquivRefreshed scope t1 t2 = refreshAST scope t1 `unsafeEqAST` refreshAST scope t2

-- | \(\alpha\)-equivalence check for two terms in one scope
-- via unification of bound variables (via 'unifyNameBinders').
--
-- Compared to 'alphaEquivRefreshed', this function might skip unnecessary
-- changes of bound variables when both binders in two matching scoped terms coincide.
alphaEquiv
  :: (Bitraversable sig, ZipMatchK sig, Foil.Distinct n, Foil.UnifiablePattern binder)
  => Foil.Scope n
  -> AST binder sig n
  -> AST binder sig n
  -> Bool
alphaEquiv _scope (Var x) (Var y) = x == coerce y
alphaEquiv scope (Node l) (Node r) =
  case zipMatch2 l r of
    Nothing -> False
    Just tt -> getAll (bifoldMap (All . uncurry (alphaEquivScoped scope)) (All . uncurry (alphaEquiv scope)) tt)
alphaEquiv _ _ _ = False

-- | Same as 'alphaEquiv' but for scoped terms.
alphaEquivScoped
  :: (Bitraversable sig, ZipMatchK sig, Foil.Distinct n, Foil.UnifiablePattern binder)
  => Foil.Scope n
  -> ScopedAST binder sig n
  -> ScopedAST binder sig n
  -> Bool
alphaEquivScoped scope
  (ScopedAST binder1 body1)
  (ScopedAST binder2 body2) =
    case Foil.unifyPatterns binder1 binder2 of
      -- if binders are the same, then we can safely compare bodies
      Foil.SameNameBinders{} ->  -- after seeing this we know that body scopes are the same
        case Foil.assertDistinct binder1 of
          Foil.Distinct ->
            let scope1 = Foil.extendScopePattern binder1 scope
            in alphaEquiv scope1 body1 body2
      -- if we can safely rename first binder into second
      Foil.RenameLeftNameBinder _ rename1to2 ->
        case Foil.assertDistinct binder2 of
          Foil.Distinct ->
            let scope2 = Foil.extendScopePattern binder2 scope
            in alphaEquiv scope2 (Foil.liftRM scope2 (Foil.fromNameBinderRenaming rename1to2) body1) body2
      -- if we can safely rename second binder into first
      Foil.RenameRightNameBinder _ rename2to1 ->
        case Foil.assertDistinct binder1 of
          Foil.Distinct ->
            let scope1 = Foil.extendScopePattern binder1 scope
            in alphaEquiv scope1 body1 (Foil.liftRM scope1 (Foil.fromNameBinderRenaming rename2to1) body2)
      -- if we need to rename both patterns
      Foil.RenameBothBinders binder' rename1 rename2 ->
        case Foil.assertDistinct binder' of
          Foil.Distinct ->
            let scope' = Foil.extendScopePattern binder' scope
            in alphaEquiv scope'
                (Foil.liftRM scope' (Foil.fromNameBinderRenaming rename1) body1)
                (Foil.liftRM scope' (Foil.fromNameBinderRenaming rename2) body2)
      -- if we cannot unify patterns then scopes are not alpha-equivalent
      Foil.NotUnifiable -> False

-- ** Unsafe equality checks

-- | /Unsafe/ equality check for two terms.
-- This check ignores the possibility that two terms might have different
-- scope extensions under binders (which might happen due to substitution
-- under a binder in absence of name conflicts).
unsafeEqAST
  :: (Bitraversable sig, ZipMatchK sig, Foil.UnifiablePattern binder, Foil.Distinct n, Foil.Distinct l)
  => AST binder sig n
  -> AST binder sig l
  -> Bool
unsafeEqAST (Var x) (Var y) = x == coerce y
unsafeEqAST (Node t1) (Node t2) =
  case zipMatch2 t1 t2 of
    Nothing -> False
    Just tt -> getAll (bifoldMap (All . uncurry unsafeEqScopedAST) (All . uncurry unsafeEqAST) tt)
unsafeEqAST _ _ = False

-- | A version of 'unsafeEqAST' for scoped terms.
unsafeEqScopedAST
  :: (Bitraversable sig, ZipMatchK sig, Foil.UnifiablePattern binder, Foil.Distinct n, Foil.Distinct l)
  => ScopedAST binder sig n
  -> ScopedAST binder sig l
  -> Bool
unsafeEqScopedAST (ScopedAST binder1 body1) (ScopedAST binder2 body2) = and
  [ Foil.unsafeEqPattern binder1 binder2
  , case (Foil.assertDistinct binder1, Foil.assertDistinct binder2) of
      (Foil.Distinct, Foil.Distinct) -> body1 `unsafeEqAST` body2
  ]

-- * Converting to and from free foil

-- ** Convert to free foil

-- | Convert a raw term into a scope-safe term.
convertToAST
  :: (Foil.Distinct n, Bifunctor sig, Ord rawIdent, Foil.CoSinkable binder)
  => (rawTerm -> Either rawIdent (sig (rawPattern, rawScopedTerm) rawTerm))
  -- ^ Unpeel one syntax node (or a variable) from a raw term.
  -> (forall x z. Foil.Distinct x
      => Foil.Scope x
      -> Map rawIdent (Foil.Name x)
      -> rawPattern
      -> (forall y. Foil.DExt x y
          => binder x y
          -> Map rawIdent (Foil.Name y)
          -> z)
      -> z)
  -- ^ Convert raw pattern into a scope-safe pattern.
  -> (rawScopedTerm -> rawTerm)
  -- ^ Extract a term from a scoped term (or crash).
  -> Foil.Scope n
  -- ^ Resulting scope of the constructed term.
  -> Map rawIdent (Foil.Name n)
  -- ^ Known names of free variables in scope @n@.
  -> rawTerm
  -- ^ Raw term.
  -> AST binder sig n
convertToAST toSig fromRawPattern getScopedTerm scope names t =
  case toSig t of
    Left x ->
      case Map.lookup x names of
        Nothing   -> error "undefined variable"
        Just name -> Var name
    Right node -> Node $
      bimap
        (convertToScopedAST toSig fromRawPattern getScopedTerm scope names)
        (convertToAST toSig fromRawPattern getScopedTerm scope names)
        node

-- | Same as 'convertToAST' but for scoped terms.
convertToScopedAST
  :: (Foil.Distinct n, Bifunctor sig, Ord rawIdent, Foil.CoSinkable binder)
  => (rawTerm -> Either rawIdent (sig (rawPattern, rawScopedTerm) rawTerm))
  -- ^ Unpeel one syntax node (or a variable) from a raw term.
  -> (forall x z. Foil.Distinct x
      => Foil.Scope x
      -> Map rawIdent (Foil.Name x)
      -> rawPattern
      -> (forall y. Foil.DExt x y
          => binder x y
          -> Map rawIdent (Foil.Name y)
          -> z)
      -> z)
  -- ^ Convert raw pattern into a scope-safe pattern.
  -> (rawScopedTerm -> rawTerm)
  -- ^ Extract a term from a scoped term (or crash).
  -> Foil.Scope n
  -- ^ Resulting scope of the constructed term.
  -> Map rawIdent (Foil.Name n)
  -- ^ Known names of free variables in scope @n@.
  -> (rawPattern, rawScopedTerm)
  -- ^ A pair of a pattern and a corresponding scoped term.
  -> ScopedAST binder sig n
convertToScopedAST toSig fromRawPattern getScopedTerm scope names (pat, scopedTerm) =
  fromRawPattern scope names pat $ \binder' names' ->
    let scope' = Foil.extendScopePattern binder' scope
     in ScopedAST binder' (convertToAST toSig fromRawPattern getScopedTerm scope' names' (getScopedTerm scopedTerm))

-- ** Convert from free foil

-- | Convert a scope-safe term back into a raw term.
convertFromAST
  :: Bifunctor sig
  => (sig (rawPattern, rawScopedTerm) rawTerm -> rawTerm)
  -- ^ Peel back one layer of syntax.
  -> (rawIdent -> rawTerm)
  -- ^ Convert identifier into a raw variable term.
  -> (forall x y. binder x y -> rawPattern)
  -- ^ Convert scope-safe pattern into a raw pattern.
  -> (rawTerm -> rawScopedTerm)
  -- ^ Wrap raw term into a scoped term.
  -> (Int -> rawIdent)
  -- ^ Convert underlying integer identifier of a bound variable into a raw identifier.
  -> AST binder sig n
  -- ^ Scope-safe term.
  -> rawTerm
convertFromAST fromSig fromVar makePattern makeScoped f = \case
  Var x -> fromVar (f (Foil.nameId x))
  Node node -> fromSig $
    bimap
      (convertFromScopedAST fromSig fromVar makePattern makeScoped f)
      (convertFromAST fromSig fromVar makePattern makeScoped f)
      node

-- | Same as 'convertFromAST' but for scoped terms.
convertFromScopedAST
  :: Bifunctor sig
  => (sig (rawPattern, rawScopedTerm) rawTerm -> rawTerm)
  -- ^ Peel back one layer of syntax.
  -> (rawIdent -> rawTerm)
  -- ^ Convert identifier into a raw variable term.
  -> (forall x y. binder x y -> rawPattern)
  -- ^ Convert scope-safe pattern into a raw pattern.
  -> (rawTerm -> rawScopedTerm)
  -- ^ Wrap raw term into a scoped term.
  -> (Int -> rawIdent)
  -- ^ Convert underlying integer identifier of a bound variable into a raw identifier.
  -> ScopedAST binder sig n
  -- ^ Scope-safe scoped term.
  -> (rawPattern, rawScopedTerm)
convertFromScopedAST fromSig fromVar makePattern makeScoped f = \case
  ScopedAST binder body ->
    ( makePattern binder
    , makeScoped (convertFromAST fromSig fromVar makePattern makeScoped f body))
