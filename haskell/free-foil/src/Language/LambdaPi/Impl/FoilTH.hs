-- {-# OPTIONS_GHC -ddump-splices #-}
{-# LANGUAGE DerivingStrategies         #-}
{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs               #-}
{-# LANGUAGE LambdaCase                 #-}
{-# LANGUAGE LiberalTypeSynonyms        #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeApplications           #-}
{-# OPTIONS_GHC -fno-warn-unused-binds  #-}
{-# OPTIONS_GHC -fno-warn-unused-matches  #-}
-- | Foil implementation of the \(\lambda\Pi\)-calculus (with pairs)
-- using Template Haskell to reduce boilerplate.
--
-- Template Haskell generation provides the following:
--
-- 1. Scope-safe AST, generated from a raw definition. See 'FoilTerm', 'FoilScopedTerm', and 'FoilPattern'.
-- 2. Conversion between scope-safe and raw term representation (the latter is generated via BNFC), see 'toFoilTerm' and 'fromFoilTerm'.
-- 3. Helper functions for patterns. See 'extendScopeFoilPattern' and 'withRefreshedFoilPattern'.
--
-- The following is implemented manually in this module:
--
-- 1. Correct capture-avoiding substitution (see 'substitute').
-- 2. Computation of weak head normal form (WHNF), see 'whnf'.
-- 3. Entry point, gluing everything together. See 'defaultMain'.
--
-- This implementation supports (nested) patterns for pairs.
module Language.LambdaPi.Impl.FoilTH where


import           Control.Monad.Foil
import           Control.Monad.Foil.TH
import qualified Language.LambdaPi.Syntax.Abs as Raw
import qualified Language.LambdaPi.Syntax.Print as Raw
import qualified Language.LambdaPi.Syntax.Par as Raw
import qualified Language.LambdaPi.Syntax.Layout as Raw
import qualified Language.LambdaPi.Syntax.Lex as Raw
import System.Exit (exitFailure)
import qualified Data.Map as Map

-- * Generated code

-- ** Scope-safe AST
mkFoilData ''Raw.Term ''Raw.VarIdent ''Raw.ScopedTerm ''Raw.Pattern
mkInstancesFoil ''Raw.Term ''Raw.VarIdent ''Raw.ScopedTerm ''Raw.Pattern

-- ** Conversion from raw to scope-safe AST
mkToFoil ''Raw.Term ''Raw.VarIdent ''Raw.ScopedTerm ''Raw.Pattern

-- ** Conversion from scope-safe to raw AST
mkFromFoil ''Raw.Term ''Raw.VarIdent ''Raw.ScopedTerm ''Raw.Pattern

-- | Convert a /closed/ scope-safe term into a raw term.
fromFoilTermClosed
  :: [Raw.VarIdent]   -- ^ A stream of fresh variable identifiers.
  -> FoilTerm VoidS       -- ^ A scope safe term in scope @n@.
  -> Raw.Term
fromFoilTermClosed freshVars = fromFoilTerm freshVars emptyNameMap

instance InjectName FoilTerm where
  injectName = FoilVar

-- * User-defined

-- ** Substitution

-- | Perform substitution in a \(\lambda\Pi\)-term.
substitute :: Distinct o => Scope o -> Substitution FoilTerm i o -> FoilTerm i -> FoilTerm o
substitute scope subst = \case
    FoilVar name -> lookupSubst subst name
    FoilApp f x -> FoilApp (substitute scope subst f) (substitute scope subst x)
    FoilLam pattern (FoilAScopedTerm body) -> withRefreshedFoilPattern scope pattern $ \extendSubst pattern' ->
      let subst' = extendSubst subst
          scope' = extendScopeFoilPattern pattern' scope
          body' = substitute scope' subst' body
       in FoilLam pattern' (FoilAScopedTerm body')
    FoilPi pattern a (FoilAScopedTerm b) -> withRefreshedFoilPattern scope pattern $ \extendSubst pattern' ->
      let subst' = extendSubst subst
          scope' = extendScopeFoilPattern pattern' scope
          a' = substitute scope subst a
          b' = substitute scope' subst' b
       in FoilPi pattern' a' (FoilAScopedTerm b')
    FoilPair l r -> FoilPair (substitute scope subst l) (substitute scope subst r)
    FoilFirst t -> FoilFirst (substitute scope subst t)
    FoilSecond t -> FoilSecond (substitute scope subst t)
    FoilProduct l r -> FoilProduct (substitute scope subst l) (substitute scope subst r)
    FoilUniverse -> FoilUniverse

-- ** Computation

-- | Match a pattern against an expression.
matchPattern :: FoilPattern n l -> FoilTerm n -> Substitution FoilTerm l n
matchPattern pattern expr = go pattern expr identitySubst
  where
    go :: FoilPattern i l -> FoilTerm n -> Substitution FoilTerm i n -> Substitution FoilTerm l n
    go FoilPatternWildcard _   = id
    go (FoilPatternVar x) e    = \subst -> addSubst subst x e
    go (FoilPatternPair l r) e = go r (FoilSecond e) . go l (FoilFirst e)

-- | Compute weak head normal form (WHNF).
whnf :: Distinct n => Scope n -> FoilTerm n -> FoilTerm n
whnf scope = \case
  FoilApp f arg ->
    case whnf scope f of
      FoilLam pat (FoilAScopedTerm body) ->
        let subst = matchPattern pat arg
         in whnf scope (substitute scope subst body)
      f' -> FoilApp f' arg
  FoilFirst t ->
    case whnf scope t of
      FoilPair l _r -> whnf scope l
      t'         -> FoilFirst t'
  FoilSecond t ->
    case whnf scope t of
      FoilPair _l r -> whnf scope r
      t'         -> FoilSecond t'
  t -> t

-- ** Interpreter

-- | Interpret a λΠ command.
interpretCommand :: Raw.Command -> IO ()
interpretCommand (Raw.CommandCompute term _type) =
  putStrLn ("  ↦ " ++ printFoilTerm (whnf emptyScope (toFoilTerm emptyScope Map.empty term)))
-- #TODO: add typeCheck
interpretCommand (Raw.CommandCheck _term _type) =
  putStrLn "Not yet implemented"

-- | Interpret a λΠ program.
interpretProgram :: Raw.Program -> IO ()
interpretProgram (Raw.AProgram typedTerms) = mapM_ interpretCommand typedTerms

-- | Default interpreter program.
-- Reads a λΠ program from the standard input and runs the commands.
defaultMain :: IO ()
defaultMain = do
  input <- getContents
  case Raw.pProgram (Raw.resolveLayout True (Raw.tokens input)) of
    Left err -> do
      putStrLn err
      exitFailure
    Right program -> interpretProgram program

-- ** Pretty-printing

-- | Pretty-print a /closed/ scode-safe \(\lambda\Pi\)-term
-- using BNFC-generated printer (via 'Raw.Term').
printFoilTerm :: FoilTerm VoidS -> String
printFoilTerm = Raw.printTree . fromFoilTermClosed
  [ Raw.VarIdent ("x" <> show i) | i <- [1 :: Integer ..] ]