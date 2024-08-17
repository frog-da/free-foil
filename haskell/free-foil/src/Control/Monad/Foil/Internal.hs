{-# LANGUAGE BlockArguments             #-}
{-# LANGUAGE ConstraintKinds            #-}
{-# LANGUAGE DataKinds                  #-}
{-# LANGUAGE EmptyCase                  #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE KindSignatures             #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE QuantifiedConstraints      #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TypeApplications           #-}
{-# LANGUAGE UndecidableInstances       #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-unrecognised-pragmas #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# OPTIONS_GHC -Wno-redundant-constraints #-}
{-# LANGUAGE DefaultSignatures          #-}
-- | Main definitions of the foil that can be
-- reused for specific implementations.
-- This is an internal module, so it also contains implementation details of the foil.
--
-- The original description of this approach
-- is described in the IFL 2022 paper by Maclaurin, Radul, and Paszke
-- [«The Foil: Capture-Avoiding Substitution With No Sharp Edges»](https://doi.org/10.1145/3587216.3587224).
-- This module also introduces 'CoSinkable' class,
-- generalizing handling of patterns, as described in
-- [«Free Foil: Generating Efficient and Scope-Safe Abstract Syntax»](https://arxiv.org/abs/2405.16384).
--
-- Since the representation of scopes and substitutions
-- is either 'IntMap' or 'IntSet', many of the operations
-- have a worst-case complexity of \(O(\min(n,W))\).
-- This means that the operation can become linear in the size of the scope \(n\) with a maximum of \(W\)
-- — the number of bits in an 'Int' (32 or 64).
module Control.Monad.Foil.Internal where

import           Control.DeepSeq (NFData (..))
import           Data.Coerce     (coerce)
import           Data.IntMap
import qualified Data.IntMap     as IntMap
import           Data.IntSet
import qualified Data.IntSet     as IntSet
import           Data.Kind       (Type)
import           Unsafe.Coerce

-- * Safe types and operations

-- | 'S' is a data kind of scope indices.
data S
  = VoidS -- ^ 'VoidS' is the only explicit scope available to the users, representing an empty scope.
          -- All other scopes are represented with type variables,
          -- bound in rank-2 polymophic functions like 'withFreshBinder'.

-- | A safe scope, indexed by a type-level scope index 'n'.
newtype Scope (n :: S) = UnsafeScope RawScope
  deriving newtype NFData

-- | A name in a safe scope, indexed by a type-level scope index 'n'.
newtype Name (n :: S) = UnsafeName RawName
  deriving newtype (NFData, Eq, Ord, Show)

-- | Convert 'Name' into an identifier.
-- This may be useful for printing and debugging.
nameId :: Name l -> Id
nameId (UnsafeName i) = i

-- | A name binder is a name that extends scope @n@ to a (larger) scope @l@.
newtype NameBinder (n :: S) (l :: S) =
  UnsafeNameBinder (Name l)
    deriving newtype (NFData, Eq, Ord, Show)

-- | An empty scope (without any names).
emptyScope :: Scope VoidS
emptyScope = UnsafeScope IntSet.empty

-- | A runtime check for potential name capture.
member :: Name l -> Scope n -> Bool
member (UnsafeName name) (UnsafeScope s) = rawMember name s

-- ** Extending scopes

-- | \(O(\min(n,W))\).
-- Extend a scope with one name (safely).
-- Note that as long as the foil is used as intended,
-- the name binder is guaranteed to introduce a name
-- that does not appear in the initial scope.
extendScope :: NameBinder n l -> Scope n -> Scope l
extendScope (UnsafeNameBinder (UnsafeName name)) (UnsafeScope scope) =
  UnsafeScope (IntSet.insert name scope)

-- | Extend scope with variables inside a pattern.
-- This is a more flexible version of 'extendScope'.
extendScopePattern
  :: (Distinct n, CoSinkable pattern)
  => pattern n l -> Scope n -> Scope l
extendScopePattern pat scope = withPattern
  (\_scope' binder k ->
    unsafeAssertFresh binder $ \binder' ->
      k (ExtendScope (extendScope binder)) binder')
  idExtendScope
  compExtendScope
  scope
  pat
  (\(ExtendScope extend) _ -> extend scope)

-- | Auxiliary data structure for scope extension. Used in 'extendScopePattern'.
newtype ExtendScope n l (o :: S) (o' :: S) = ExtendScope (Scope n -> Scope l)

-- | Identity scope extension (no extension).
idExtendScope :: ExtendScope n n o o'
idExtendScope = ExtendScope id

-- | Compose scope extensions.
compExtendScope
  :: ExtendScope n i o o'
  -> ExtendScope i l o' o''
  -> ExtendScope n l o o''
compExtendScope (ExtendScope f) (ExtendScope g)
  = ExtendScope (g . f)

-- ** Collecting new names

-- | Extract name from a name binder.
nameOf :: NameBinder n l -> Name l
nameOf (UnsafeNameBinder name) = name

-- | Extract names from a pattern.
-- This is a more flexible version of 'namesOf'.
namesOfPattern
  :: forall pattern n l. (Distinct n, CoSinkable pattern) => pattern n l -> [Name l]
namesOfPattern pat = withPattern @_ @n
  (\_scope' binder k ->
    unsafeAssertFresh binder $ \binder' ->
      k (NamesOf [nameOf binder]) binder')
  idNamesOf compNamesOf (error "impossible") pat
  (\(NamesOf names) _ -> names)

-- | Auxiliary structure collecting names in scope @l@ that extend scope @n@.
-- Used in 'namesOfPattern'.
newtype NamesOf (n :: S) l (o :: S) (o' :: S) = NamesOf [Name l]

-- | Empty list of names in scope @n@.
idNamesOf :: NamesOf n n o o'
idNamesOf = NamesOf []

-- | Concatenation of names, resulting in a list of names in @l@ that extend scope @n@.
compNamesOf :: NamesOf n i o o' -> NamesOf i l o' o'' -> NamesOf n l o o''
compNamesOf (NamesOf xs) (NamesOf ys) =
  NamesOf (coerce xs ++ ys)

-- ** Refreshing binders

-- | Allocate a fresh binder for a given scope.
withFreshBinder
  :: Scope n
  -> (forall l. NameBinder n l -> r) -> r
withFreshBinder (UnsafeScope scope) cont =
  cont binder
  where
    binder = UnsafeNameBinder (UnsafeName (rawFreshName scope))

-- | Safely produce a fresh name binder with respect to a given scope.
withFresh
  :: Distinct n => Scope n
  -> (forall l. DExt n l => NameBinder n l -> r) -> r
withFresh scope cont = withFreshBinder scope (`unsafeAssertFresh` cont)

-- | Rename a given pattern into a fresh version of it to extend a given scope.
--
-- This is similar to 'withRefreshPattern', except here renaming always takes place.
withFreshPattern
  :: (Distinct o, CoSinkable pattern, Sinkable e, InjectName e)
  => Scope o      -- ^ Ambient scope.
  -> pattern n l  -- ^ Pattern to refresh (if it clashes with the ambient scope).
  -> (forall o'. DExt o o' => (Substitution e n o -> Substitution e l o') -> pattern o o' -> r)
  -- ^ Continuation, accepting the refreshed pattern.
  -> r
withFreshPattern scope pattern cont = withPattern
  (\scope' binder f -> withFresh scope'
    (\binder' -> f (WithRefreshedPattern (\subst -> addRename (sink subst) binder (nameOf binder'))) binder'))
  idWithRefreshedPattern
  compWithRefreshedPattern
  scope
  pattern
  (\(WithRefreshedPattern f) pattern' -> cont f pattern')

-- | Safely rename (if necessary) a given name to extend a given scope.
-- This is similar to 'withFresh', except if the name does not clash with
-- the scope, it can be used immediately, without renaming.
withRefreshed
  :: Distinct o
  => Scope o    -- ^ Ambient scope.
  -> Name i     -- ^ Name to refresh (if it clashes with the ambient scope).
  -> (forall o'. DExt o o' => NameBinder o o' -> r)
  -- ^ Continuation, accepting the refreshed name.
  -> r
withRefreshed scope@(UnsafeScope rawScope) name@(UnsafeName rawName) cont
  | IntSet.member rawName rawScope = withFresh scope cont
  | otherwise = unsafeAssertFresh (UnsafeNameBinder name) cont

-- | Safely rename (if necessary) a given pattern to extend a given scope.
-- This is similar to 'withFreshPattern', except if a name in the pattern
-- does not clash with the scope, it can be used immediately, without renaming.
--
-- This is a more general version of 'withRefreshed'.
withRefreshedPattern
  :: (Distinct o, CoSinkable pattern, Sinkable e, InjectName e)
  => Scope o      -- ^ Ambient scope.
  -> pattern n l  -- ^ Pattern to refresh (if it clashes with the ambient scope).
  -> (forall o'. DExt o o' => (Substitution e n o -> Substitution e l o') -> pattern o o' -> r)
  -- ^ Continuation, accepting the refreshed pattern.
  -> r
withRefreshedPattern scope pattern cont = withPattern
  (\scope' binder f -> withRefreshed scope' (nameOf binder)
    (\binder' -> f (WithRefreshedPattern (\subst -> addRename (sink subst) binder (nameOf binder'))) binder'))
  idWithRefreshedPattern
  compWithRefreshedPattern
  scope
  pattern
  (\(WithRefreshedPattern f) pattern' -> cont f pattern')

-- | Refresh (if needed) bound variables introduced in a pattern.
--
-- This is a version of 'withRefreshedPattern' that uses functional renamings instead of 'Substitution'.
withRefreshedPattern'
  :: (CoSinkable pattern, Distinct o, InjectName e, Sinkable e)
  => Scope o
  -> pattern n l
  -> (forall o'. DExt o o' => ((Name n -> e o) -> Name l -> e o') -> pattern o o' -> r) -> r
withRefreshedPattern' scope pattern cont = withPattern
  (\scope' binder f -> withRefreshed scope' (nameOf binder)
    (\binder' ->
      let k subst name = case unsinkName binder name of
              Nothing    -> injectName (nameOf binder')
              Just name' -> sink (subst name')
       in f (WithRefreshedPattern' k) binder'))
  idWithRefreshedPattern'
  compWithRefreshedPattern'
  scope
  pattern
  (\(WithRefreshedPattern' f) pattern' -> cont f pattern')

-- | Unsafely declare that a given name (binder)
-- is already fresh in any scope @n'@.
unsafeAssertFresh :: forall n l n' l' r. NameBinder n l
  -> (DExt n' l' => NameBinder n' l' -> r) -> r
unsafeAssertFresh binder cont =
  case unsafeDistinct @l' of
    Distinct -> case unsafeExt @n' @l' of
      Ext -> cont (unsafeCoerce binder)

-- | Auxiliary structure to accumulate substitution extensions
-- produced when refreshing a pattern.
-- Used in 'withRefreshedPattern' and 'withFreshPattern'.
newtype WithRefreshedPattern e n l o o' = WithRefreshedPattern (Substitution e n o -> Substitution e l o')

-- | Trivial substitution (coercion via 'sink').
idWithRefreshedPattern :: (Sinkable e, DExt o o') => WithRefreshedPattern e n n o o'
idWithRefreshedPattern = WithRefreshedPattern sink

-- | Composition of substitution extensions.
compWithRefreshedPattern
  :: (DExt o o', DExt o' o'')
  => WithRefreshedPattern e n i o o'
  -> WithRefreshedPattern e i l o' o''
  -> WithRefreshedPattern e n l o o''
compWithRefreshedPattern (WithRefreshedPattern f) (WithRefreshedPattern g) =
  WithRefreshedPattern (g . f)

-- | Auxiliary structure to accumulate substitution extensions
-- produced when refreshing a pattern.
-- Similar to 'WithRefreshedPattern', except here substitutions are represented as functions.
-- Used in 'withRefreshedPattern''.
newtype WithRefreshedPattern' e n l (o :: S) (o' :: S) = WithRefreshedPattern' ((Name n -> e o) -> Name l -> e o')

-- | Trivial substitution extension (coercion via 'sink').
idWithRefreshedPattern' :: (Sinkable e, DExt o o') => WithRefreshedPattern' e n n o o'
idWithRefreshedPattern' = WithRefreshedPattern' (\f n -> sink (f n))

-- | Composition of substitution extensions.
compWithRefreshedPattern'
  :: (DExt o o', DExt o' o'')
  => WithRefreshedPattern' e n i o o'
  -> WithRefreshedPattern' e i l o' o''
  -> WithRefreshedPattern' e n l o o''
compWithRefreshedPattern' (WithRefreshedPattern' f) (WithRefreshedPattern' g) =
  WithRefreshedPattern' (g . f)

-- ** Extracting proofs from binders and patterns

-- | Evidence that scope @n@ contains distinct names.
data DistinctEvidence (n :: S) where
  Distinct :: Distinct n => DistinctEvidence n

-- | Evidence that scope @l@ extends scope @n@.
data ExtEvidence (n :: S) (l :: S) where
  Ext :: Ext n l => ExtEvidence n l

-- | A distinct scope extended with a 'NameBinder' is also distinct.
assertDistinct :: (Distinct n, CoSinkable pattern) => pattern n l -> DistinctEvidence l
assertDistinct _ = unsafeDistinct

-- | A distinct scope extended with a 'NameBinder' is also distinct.
assertExt :: CoSinkable pattern => pattern n l -> ExtEvidence n l
assertExt _ = unsafeExt

-- | Unsafely declare that scope @n@ is distinct.
-- Used in 'unsafeAssertFresh'.
unsafeDistinct :: DistinctEvidence n
unsafeDistinct = unsafeCoerce (Distinct :: DistinctEvidence VoidS)

-- | Unsafely declare that scope @l@ extends scope @n@.
-- Used in 'unsafeAssertFresh'.
unsafeExt :: ExtEvidence n l
unsafeExt = unsafeCoerce (Ext :: ExtEvidence VoidS VoidS)

-- ** Unsinking names

-- | Try coercing the name back to the (smaller) scope,
-- given a binder that extends that scope.
unsinkName :: NameBinder n l -> Name l -> Maybe (Name n)
unsinkName binder name@(UnsafeName raw)
  | nameOf binder == name = Nothing
  | otherwise = Just (UnsafeName raw)

-- | Check if a name in the extended context
-- is introduced in a pattern or comes from the outer scope @n@.
--
-- This is a generalization of 'unsinkName'.
unsinkNamePattern
  :: forall pattern n l. (Distinct n, CoSinkable pattern)
  => pattern n l -> Name l -> Maybe (Name n)
unsinkNamePattern pat = withPattern @_ @n
  (\_scope' binder k ->
      unsafeAssertFresh binder $ \binder' ->
        k (UnsinkName (unsinkName binder)) binder')
  idUnsinkName
  compUnsinkName
  (error "impossible")  -- scope is not used, but has to be provided in general
  pat
  (\(UnsinkName unsink) _ -> unsink)

-- | Auxiliary structure for unsinking names.
-- Used in 'unsinkNamePattern'.
newtype UnsinkName n l (o :: S) (o' :: S) = UnsinkName (Name l -> Maybe (Name n))

-- | Trivial unsinking. If no scope extension took place, any name is free (since it cannot be bound by anything).
idUnsinkName :: UnsinkName n n o o'
idUnsinkName = UnsinkName Just

-- | Composition of unsinking for nested binders/patterns.
compUnsinkName
  :: UnsinkName n i o o'
  -> UnsinkName i l o' o''
  -> UnsinkName n l o o''
compUnsinkName (UnsinkName f) (UnsinkName g)
  = UnsinkName (\name -> g name >>= f)

-- * Unification of binders

-- | Unification result for two binders,
-- extending some common scope to scopes @l@ and @r@ respectively.
--
-- Due to the implementation of the foil, we can often rename binders efficiently,
-- by renaming binders only in one of the two unified terms.
data UnifyNameBinders (pattern :: S -> S -> Type) n l r where
  -- | Binders are the same, proving that type parameters @l@ and @r@
  -- are in fact equivalent.
  SameNameBinders
    :: NameBinders n l  -- ^ /Unordered/ set of binders in the unified pattern (from any of the original patterns).
    -> UnifyNameBinders pattern n l l
  -- | It is possible to safely rename the left binder
  -- to match the right one.
  RenameLeftNameBinder
    :: NameBinders n r                    -- ^ /Unordered/ set of binders in the unified pattern (the binders from the right pattern).
    -> (NameBinder n l -> NameBinder n r) -- ^ Binder renaming for the left pattern.
    -> UnifyNameBinders pattern n l r
  -- | It is possible to safely rename the right binder
  -- to match the left one.
  RenameRightNameBinder
    :: NameBinders n l                    -- ^ /Unordered/ set of binders in the unified pattern (the binders from the left pattern).
    -> (NameBinder n r -> NameBinder n l) -- ^ Binder renaming for the right pattern.
    -> UnifyNameBinders pattern n l r
  -- | It is necessary to rename both binders.
  RenameBothBinders
    :: NameBinders n lr                     -- ^ /Unordered/ set of binders in the unified pattern
    -> (NameBinder n l -> NameBinder n lr)  -- ^ Binder renaming for the left pattern.
    -> (NameBinder n r -> NameBinder n lr)  -- ^ Binder renaming for the right pattern.
    -> UnifyNameBinders pattern n l r
  -- | Cannot unify to (sub)patterns.
  NotUnifiable :: UnifyNameBinders pattern n l r

-- | Unify binders either by asserting that they are the same,
-- or by providing a /safe/ renaming function to convert one binder to another.
unifyNameBinders
  :: forall i l r pattern. Distinct i
  => NameBinder i l -- ^ Left pattern.
  -> NameBinder i r -- ^ Right pattern.
  -> UnifyNameBinders pattern i l r
unifyNameBinders l@(UnsafeNameBinder (UnsafeName i1)) r@(UnsafeNameBinder (UnsafeName i2))
  | i1 == i2  = case assertDistinct l of
      Distinct -> unsafeCoerce (SameNameBinders (nameBindersSingleton l))  -- equal names extend scopes equally
  | i1 < i2   = RenameRightNameBinder (nameBindersSingleton l) $ \(UnsafeNameBinder (UnsafeName i'')) ->
      if i'' == i2 then UnsafeNameBinder (UnsafeName i1) else UnsafeNameBinder (UnsafeName i'')
  | otherwise = RenameLeftNameBinder (nameBindersSingleton r) $ \(UnsafeNameBinder (UnsafeName i')) ->
      if i'  == i1 then UnsafeNameBinder (UnsafeName i2) else UnsafeNameBinder (UnsafeName i')

-- | Unsafely merge results of unification for nested binders/patterns.
-- Used in 'andThenUnifyPatterns'.
unsafeMergeUnifyBinders :: UnifyNameBinders pattern a a' a'' -> UnifyNameBinders pattern a''' b' b'' -> UnifyNameBinders pattern a b' b''
unsafeMergeUnifyBinders = \case

  SameNameBinders x -> \case
    SameNameBinders y -> SameNameBinders (x `unsafeMergeNameBinders` y)
    RenameLeftNameBinder y f -> RenameLeftNameBinder (x `unsafeMergeNameBinders` y) (unsafeCoerce f)
    RenameRightNameBinder y g -> RenameRightNameBinder (x `unsafeMergeNameBinders` y) (unsafeCoerce g)
    RenameBothBinders y f g -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f) (unsafeCoerce g)
    NotUnifiable -> NotUnifiable

  RenameLeftNameBinder x f -> \case
    SameNameBinders y -> RenameLeftNameBinder (x `unsafeMergeNameBinders` y) (unsafeCoerce f)
    RenameLeftNameBinder y g -> RenameLeftNameBinder (x `unsafeMergeNameBinders` y) (unsafeCoerce f . unsafeCoerce g)
    RenameRightNameBinder y g -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f) (unsafeCoerce g)
    RenameBothBinders y f' g -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f . unsafeCoerce f') (unsafeCoerce g)
    NotUnifiable -> NotUnifiable

  RenameRightNameBinder x g -> \case
    SameNameBinders y -> RenameRightNameBinder (x `unsafeMergeNameBinders` y) (unsafeCoerce g)
    RenameLeftNameBinder y f -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f) (unsafeCoerce g)
    RenameRightNameBinder y g' -> RenameRightNameBinder (x `unsafeMergeNameBinders` y) (unsafeCoerce g . unsafeCoerce g')
    RenameBothBinders y f g' -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f) (unsafeCoerce g . unsafeCoerce g')
    NotUnifiable -> NotUnifiable

  RenameBothBinders x f g -> \case
    SameNameBinders y -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f) (unsafeCoerce g)
    RenameLeftNameBinder y f' -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f . unsafeCoerce f') (unsafeCoerce g)
    RenameRightNameBinder y g' -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f) (unsafeCoerce g . unsafeCoerce g')
    RenameBothBinders y f' g' -> RenameBothBinders (x `unsafeMergeNameBinders` y) (unsafeCoerce f . unsafeCoerce f') (unsafeCoerce g . unsafeCoerce g')
    NotUnifiable -> NotUnifiable

  NotUnifiable -> const (NotUnifiable)

-- | Chain unification of nested patterns.
andThenUnifyPatterns
  :: (UnifiablePattern pattern, Distinct l, Distinct l')
  => UnifyNameBinders pattern n l l'    -- ^ Unifying action for some outer patterns.
  -> (pattern l r, pattern l' r')       -- ^ Two nested patterns (cannot be unified directly since they extend different scopes).
  -> UnifyNameBinders pattern n r r'
andThenUnifyPatterns u (l, r) = unsafeMergeUnifyBinders u (unifyPatterns (unsafeCoerce l) r)

-- | Chain unification of nested patterns with 'NameBinder's.
andThenUnifyNameBinders
  :: (UnifiablePattern pattern, Distinct l, Distinct l')
  => UnifyNameBinders pattern n l l'    -- ^ Unifying action for some outer patterns.
  -> (NameBinder l r, NameBinder l' r') -- ^ Two nested binders (cannot be unified directly since they extend different scopes).
  -> UnifyNameBinders pattern n r r'
andThenUnifyNameBinders u (l, r) = unsafeMergeUnifyBinders u (unifyNameBinders (unsafeCoerce l) r)

-- | An /unordered/ collection of 'NameBinder's, that together extend scope @n@ to scope @l@.
--
-- For an ordered version see 'NameBinderList'.
newtype NameBinders (n :: S) (l :: S) = UnsafeNameBinders IntSet

-- | /Unsafely/ merge sets of binders (via set union).
unsafeMergeNameBinders :: NameBinders a b -> NameBinders c d -> NameBinders n l
unsafeMergeNameBinders (UnsafeNameBinders x) (UnsafeNameBinders y) = UnsafeNameBinders (x <> y)

-- | An empty set of binders keeps the scope as is.
emptyNameBinders :: NameBinders n n
emptyNameBinders = UnsafeNameBinders IntSet.empty

-- | Composition of sets of binders.
mergeNameBinders :: NameBinders n i -> NameBinders i l -> NameBinders n l
mergeNameBinders = unsafeMergeNameBinders

-- | A singleton name binder set.
nameBindersSingleton :: NameBinder n l -> NameBinders n l
nameBindersSingleton binder = UnsafeNameBinders (IntSet.singleton (nameId (nameOf binder)))

-- | An /ordered/ collection (list) of 'NameBinder's, that together extend scope @n@ to scope @l@.
--
-- For an unordered version see 'NameBinders'.
data NameBinderList n l where
  -- | An empty list of binders keeps the scope as is.
  NameBinderListEmpty :: NameBinderList n n
  -- | A non-empty list of binders.
  NameBinderListCons
    :: NameBinder n i       -- ^ Outermost binder.
    -> NameBinderList i l   -- ^ Remaining list of binders.
    -> NameBinderList n l

-- | Convert an unordered set of name binders into an ordered list (with some order).
nameBindersList :: NameBinders n l -> NameBinderList n l
nameBindersList (UnsafeNameBinders names) = go (IntSet.toList names)
  where
    go []     = unsafeCoerce NameBinderListEmpty
    go (x:xs) = NameBinderListCons (UnsafeNameBinder (UnsafeName x)) (go xs)

-- | Convert an ordered list of name binders into an unordered set.
fromNameBindersList :: NameBinderList n l -> NameBinders n l
fromNameBindersList = UnsafeNameBinders . IntSet.fromList . go
  where
    go :: NameBinderList n l -> [RawName]
    go NameBinderListEmpty                 = []
    go (NameBinderListCons binder binders) = nameId (nameOf binder) : go binders

instance CoSinkable NameBinders where
  coSinkabilityProof _rename (UnsafeNameBinders names) cont =
    cont unsafeCoerce (UnsafeNameBinders names)

  withPattern withBinder unit comp scope binders cont =
    withPattern withBinder unit comp scope (nameBindersList binders) $ \f binders' ->
      cont f (fromNameBindersList binders')

instance CoSinkable NameBinderList where
  coSinkabilityProof rename NameBinderListEmpty cont = cont rename NameBinderListEmpty
  coSinkabilityProof rename (NameBinderListCons binder binders) cont =
    coSinkabilityProof rename binder $ \rename' binder' ->
      coSinkabilityProof rename' binders $ \rename'' binders' ->
        cont rename'' (NameBinderListCons binder' binders')

  withPattern withBinder unit comp scope binders cont = case binders of
    NameBinderListEmpty -> cont unit NameBinderListEmpty
    NameBinderListCons x xs ->
      withBinder scope x $ \f x' ->
        let scope' = extendScopePattern x' scope
        in withPattern withBinder unit comp scope' xs $ \f' xs' ->
            cont (comp f f') (NameBinderListCons x' xs')

-- ** Pattern combinators

-- | An empty pattern type specifies zero possibilities for patterns.
--
-- This type can be used to specify that patterns are not possible.
data V2 (n :: S) (l :: S)

-- | Since 'V2' values logically don't exist, this witnesses the logical reasoning tool of "ex falso quodlibet".
absurd2 :: V2 n l -> a
absurd2 v2 = case v2 of {}

instance CoSinkable V2 where
  coSinkabilityProof _ v2 _ = absurd2 v2
  withPattern _ _ _ _ v2 _ = absurd2 v2
instance UnifiablePattern V2 where
  unifyPatterns = absurd2

-- | A unit pattern type corresponds to a wildcard pattern.
data U2 (n :: S) (l :: S) where
  U2 :: U2 n n  -- ^ Wildcard patten does not modify the scope.

instance CoSinkable U2 where
  coSinkabilityProof rename U2 cont = cont rename U2
  withPattern _withBinder unit _combine _scope U2 cont = cont unit U2
instance UnifiablePattern U2 where
  unifyPatterns U2 U2 = SameNameBinders emptyNameBinders

-- ** Unifiable patterns

-- | A pattern type is unifiable if it is possible to match two
-- patterns and decide how to rename binders.
class CoSinkable pattern => UnifiablePattern pattern where
  -- | Unify two patterns and decide which binders need to be renamed.
  unifyPatterns :: Distinct n => pattern n l -> pattern n r -> UnifyNameBinders pattern n l r

-- | Unification of values in patterns.
-- By default, 'Eq' instance is used, but it may be useful to ignore
-- some data in pattens (such as location annotations).
class UnifiableInPattern a where
  -- | Unify non-binding components of a pattern.
  unifyInPattern :: a -> a -> Bool
  default unifyInPattern :: Eq a => a -> a -> Bool
  unifyInPattern = (==)

instance UnifiablePattern NameBinder where
  unifyPatterns = unifyNameBinders

-- | The easiest way to compare two patterns is to check if they are the same.
-- This function is labelled /unsafe/, since we generally are interested in proper α-equivalence
-- instead of direct equality.
unsafeEqPattern :: (UnifiablePattern pattern, Distinct n) => pattern n l -> pattern n' l' -> Bool
unsafeEqPattern l r =
  case unifyPatterns l (unsafeCoerce r) of
    SameNameBinders{} -> True
    _                 -> False

-- * Safe sinking

-- | Sinking an expression from scope @n@ into a (usualy extended) scope @l@,
-- given the renaming (injection from scope @n@ to scope @l@).
class Sinkable (e :: S -> Type) where
  -- | An implementation of this method that typechecks
  -- proves to the compiler that the expression is indeed
  -- 'Sinkable'. However, instead of this implementation, 'sink'
  -- should be used at all call sites for efficiency.
  sinkabilityProof
    :: (Name n -> Name l)   -- ^ Map names from scope @n@ to a (possibly larger) scope @l@.
    -> e n                  -- ^ Expression with free variables in scope @n@.
    -> e l

-- | Sinking a 'Name' is as simple as applying the renaming.
instance Sinkable Name where
  sinkabilityProof rename = rename

-- | Efficient version of 'sinkabilityProof'.
-- In fact, once 'sinkabilityProof' typechecks,
-- it is safe to 'sink' by coercion.
-- See Section 3.5 in [«The Foil: Capture-Avoiding Substitution With No Sharp Edges»](https://doi.org/10.1145/3587216.3587224) for the details.
sink :: (Sinkable e, DExt n l) => e n -> e l
sink = unsafeCoerce

-- | Extend renaming when going under a 'CoSinkable' pattern (generalized binder).
-- Note that the scope under pattern is independent of the codomain of the renaming.
--
-- This function is used to go under binders when implementing 'sinkabilityProof'
-- and is both a generalization of 'extendRenamingNameBinder' and an efficient implementation of 'coSinkabilityProof'.
extendRenaming
  :: CoSinkable pattern
  => (Name n -> Name n')  -- ^ Map names from scope @n@ to a (possibly larger) scope @n'@.
  -> pattern n l          -- ^ A pattern that extends scope @n@ to another scope @l@.
  -> (forall l'. (Name l -> Name l') -> pattern n' l' -> r )
  -- ^ A continuation, accepting an extended renaming from @l@ to @l'@ (which itself extends @n'@)
  -- and a (possibly refreshed) pattern that extends @n'@ to @l'@.
  -> r
extendRenaming _ pattern cont =
  cont unsafeCoerce (unsafeCoerce pattern)

-- | Extend renaming of binders when going under a 'CoSinkable' pattern (generalized binder).
-- Note that the scope under pattern is independent of the codomain of the renaming.
extendNameBinderRenaming
  :: CoSinkable pattern
  => (NameBinder i n -> NameBinder i n')  -- ^ Map names from scope @n@ to a (possibly larger) scope @n'@.
  -> pattern n l          -- ^ A pattern that extends scope @n@ to another scope @l@.
  -> (forall l'. (NameBinder n' l -> NameBinder n' l') -> pattern n' l' -> r )
  -- ^ A continuation, accepting an extended renaming from @l@ to @l'@ (which itself extends @n'@)
  -- and a (possibly refreshed) pattern that extends @n'@ to @l'@.
  -> r
extendNameBinderRenaming _ pattern cont =
  cont unsafeCoerce (unsafeCoerce pattern)

-- | Safely compose renamings of name binders.
-- The underlying implementation is
composeNameBinderRenamings
  :: (NameBinder n i -> NameBinder n i')    -- ^ Rename binders extending scope @n@ from @i@ to @i'@.
  -> (NameBinder i' l -> NameBinder i' l')  -- ^ Rename binders extending scope @i'@ from @l@ to @l'@.
  -> (NameBinder n l -> NameBinder n l')
composeNameBinderRenamings = unsafeCoerce (flip (.))

-- | Convert renaming of name binders into renaming of names in the inner scopes.
fromNameBinderRenaming :: (NameBinder n l -> NameBinder n l') -> Name l -> Name l'
fromNameBinderRenaming = coerce

-- | Extend renaming when going under a 'NameBinder'.
-- Note that the scope under binder is independent of the codomain of the renaming.
--
-- Semantically, this function may need to rename the binder (resulting in the new scope @l'@),
-- to make sure it does not clash with scope @n'@.
-- However, as it turns out, the foil makes it safe
-- to implement this function as a coercion.
-- See Appendix A in [«The Foil: Capture-Avoiding Substitution With No Sharp Edges»](https://doi.org/10.1145/3587216.3587224) for the details.
--
-- This function is used to go under binders when implementing 'sinkabilityProof'.
-- A generalization of this function is 'extendRenaming' (which is an efficient version of 'coSinkabilityProof').
extendRenamingNameBinder
  :: (Name n -> Name n')  -- ^ Map names from scope @n@ to a (possibly larger) scope @n'@.
  -> NameBinder n l       -- ^ A name binder that extends scope @n@ to another scope @l@.
  -> (forall l'. (Name l -> Name l') -> NameBinder n' l' -> r )
  -- ^ A continuation, accepting an extended renaming from @l@ to @l'@ (which itself extends @n'@)
  -- and a (possibly refreshed) binder that extends @n'@ to @l'@.
  -> r
extendRenamingNameBinder _ (UnsafeNameBinder name) cont =
  cont unsafeCoerce (UnsafeNameBinder name)

-- | 'CoSinkable' is to patterns (generalized binders)
-- what 'Sinkable' is to expressions.
--
-- See Section 2.3 of [«Free Foil: Generating Efficient and Scope-Safe Abstract Syntax»](https://arxiv.org/abs/2405.16384) for more details.
class CoSinkable (pattern :: S -> S -> Type) where
  -- | An implementation of this method that typechecks
  -- proves to the compiler that the pattern is indeed
  -- 'CoSinkable'. However, instead of this implementation,
  -- 'extendRenaming' should be used at all call sites for efficiency.
  coSinkabilityProof
    :: (Name n -> Name n')  -- ^ Map names from scope @n@ to a (possibly larger) scope @n'@.
    -> pattern n l          -- ^ A pattern that extends scope @n@ to another scope @l@.
    -> (forall l'. (Name l -> Name l') -> pattern n' l' -> r)
    -- ^ A continuation, accepting an extended renaming from @l@ to @l'@ (which itself extends @n'@)
    -- and a (possibly refreshed) pattern that extends @n'@ to @l'@.
    -> r

  -- | Generalized processing of a pattern.
  --
  -- You can see 'withPattern' as a CPS-style traversal over the binders in a pattern.
  withPattern
    :: Distinct o
    => (forall x y z r'. Distinct z => Scope z -> NameBinder x y -> (forall z'. DExt z z' => f x y z z' -> NameBinder z z' -> r') -> r')
    -- ^ Processing of a single 'NameBinder', this will be applied to each binder in a pattern.
    -> (forall x z z'. DExt z z' => f x x z z')
    -- ^ Result in case no binders are present. This can be seen as scope-indexed 'mempty'.
    -> (forall x y y' z z' z''. (DExt z z', DExt z' z'') => f x y z z' -> f y y' z' z'' -> f x y' z z'')
    -- ^ Composition of results for nested binders/patterns. This can be seen as scope-indexed 'mappend'.
    -> Scope o
    -- ^ Ambient scope.
    -> pattern n l
    -- ^ Pattern to process.
    -> (forall o'. DExt o o' => f n l o o' -> pattern o o' -> r)
    -- ^ Continuation, accepting result for the entire pattern and a (possibly refreshed) pattern.
    -> r

instance CoSinkable NameBinder where
  coSinkabilityProof _rename (UnsafeNameBinder name) cont =
    cont unsafeCoerce (UnsafeNameBinder name)

  withPattern f _ _ = f

-- * Safe substitions

-- | A substitution is a mapping from names in scope @i@
-- to expressions @e o@ in scope @o@.
newtype Substitution (e :: S -> Type) (i :: S) (o :: S) =
  UnsafeSubstitution (IntMap (e o))

-- | Apply substitution to a given name.
lookupSubst :: InjectName e => Substitution e i o -> Name i -> e o
lookupSubst (UnsafeSubstitution env) (UnsafeName name) =
    case IntMap.lookup name env of
        Just ex -> ex
        Nothing -> injectName (UnsafeName name)

-- | Identity substitution maps all names to expresion-variables.
identitySubst
  :: InjectName e => Substitution e i i
identitySubst = UnsafeSubstitution IntMap.empty

-- | Extend substitution with a particular mapping.
addSubst
  :: Substitution e i o
  -> NameBinder i i'
  -> e o
  -> Substitution e i' o
addSubst (UnsafeSubstitution env) (UnsafeNameBinder (UnsafeName name)) ex
  = UnsafeSubstitution (IntMap.insert name ex env)

-- | Add variable renaming to a substitution.
-- This includes the performance optimization of eliding names mapped to themselves.
addRename :: InjectName e => Substitution e i o -> NameBinder i i' -> Name o -> Substitution e i' o
addRename s@(UnsafeSubstitution env) b@(UnsafeNameBinder (UnsafeName name1)) n@(UnsafeName name2)
    | name1 == name2 = UnsafeSubstitution (IntMap.delete name1 env)
    | otherwise = addSubst s b (injectName n)

-- | Substitutions are sinkable as long as corresponding expressions are.
instance (Sinkable e) => Sinkable (Substitution e i) where
  sinkabilityProof rename (UnsafeSubstitution env) =
    UnsafeSubstitution (fmap (sinkabilityProof rename) env)

-- * 'Name' maps

-- | A /total/ map from names in scope @n@ to elements of type @a@.
newtype NameMap (n :: S) a = NameMap { getNameMap :: IntMap a }

-- | An empty map belongs in the empty scope.
emptyNameMap :: NameMap VoidS a
emptyNameMap = NameMap IntMap.empty

-- | Looking up a name should always succeed.
--
-- Note that since 'Name' is 'Sinkable', you can lookup a name from scope @n@ in a 'NameMap' for scope @l@ whenever @l@ extends @n@.
lookupName :: Name n -> NameMap n a -> a
lookupName name (NameMap m) =
  case IntMap.lookup (nameId name) m of
    Nothing -> error "impossible: unknown name in a NameMap"
    Just x  -> x

-- | Extending a map with a single mapping.
--
-- Note that the scope parameter of the result differs from the initial map.
addNameBinder :: NameBinder n l -> a -> NameMap n a -> NameMap l a
addNameBinder name x (NameMap m) = NameMap (IntMap.insert (nameId (nameOf name)) x m)

-- * Raw types and operations

-- | We will use 'Int' for efficient representation of identifiers.
type Id = Int

-- | Raw name is simply an identifier.
type RawName = Id

-- | A raw scope is a set of raw names.
type RawScope = IntSet

-- | \(O(\min(n, W))\).
-- Generate a fresh raw name that
-- does not appear in a given raw scope.
rawFreshName :: RawScope -> RawName
rawFreshName scope | IntSet.null scope = 0
                   | otherwise = IntSet.findMax scope + 1

-- | Check if a raw name is contained in a raw scope.
rawMember :: RawName -> RawScope -> Bool
rawMember = IntSet.member

-- * Constraints

-- | Every scope is a (trivial) extension of itself.
--
-- __Important__: this class exists to assist tracking scope extensions
-- for type variables of kind 'S'.
-- Users of the foil are not supposed to implement any instances of 'ExtEndo'.
class ExtEndo (n :: S)

-- | Some scopes are extensions of other scopes.
--
-- __Important__: this class exists to assist tracking scope extensions
-- for type variables of kind 'S'.
-- Users of the foil are not supposed to implement any instances of 'Ext'.
class (ExtEndo n => ExtEndo l ) => Ext (n :: S) (l :: S)
instance ( ExtEndo n => ExtEndo l ) => Ext n l

-- | Scopes with distinct names.
--
-- __Important__: this class exists to explicitly
-- mark scopes with distinct names.
-- Users of the foil are not supposed to implement any instances of 'Distinct'.
class Distinct (n :: S)
instance Distinct VoidS

-- | Scope extensions with distinct names.
type DExt n l = (Distinct l, Ext n l)

-- | Instances of this typeclass possess the ability to inject names.
-- Usually, this is a variable data constructor.
class InjectName (e :: S -> Type) where
  -- | Inject names into expressions.
  injectName :: Name n -> e n
