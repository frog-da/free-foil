{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TemplateHaskellQuotes #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# OPTIONS_GHC -Wno-incomplete-patterns #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}
module Language.LambdaPi.Foil.TH.MkToFoil (mkToFoil) where

import Language.Haskell.TH

import qualified Language.LambdaPi.Foil as Foil
import Data.Maybe (fromJust)
import Data.Coerce (coerce)

-- Foil

-- data FoilTerm n where
--   FoilVar :: Foil.Name n -> FoilTerm n
--   FoilApp :: FoilTerm n -> FoilTerm n -> FoilTerm n
--   FoilLam :: FoilPattern n l -> FoilTerm l -> FoilTerm n

-- data FoilPattern n l where
--   FoilPatternVar :: Foil.NameBinder n l -> FoilPattern n l

-- data FoilScopedTerm n where
--   FoilScopedTerm :: FoilTerm n -> FoilScopedTerm n

mkToFoil :: Name -> Name -> Name -> Name -> Q [Dec]
mkToFoil termT nameT scopeT patternT = do
  n <- newName "n"
  l <- newName "l"
  TyConI (DataD _ctx _name _tvars _kind patternCons _deriv) <- reify patternT
  TyConI (DataD _ctx _name _tvars _kind scopeCons _deriv) <- reify scopeT
  TyConI (DataD _ctx _name _tvars _kind termCons _deriv) <- reify termT

  let toFoilTBody = NormalB (LamCaseE (map toMatchTerm termCons))
  let toFoilPatternBody = NormalB (LamCaseE (map toFoilPatternMatch patternCons))
  let toFoilScopedBody = NormalB (LamCaseE (map toFoilScopedMatch scopeCons))
  let withPatternBody = NormalB (CaseE (VarE (mkName "pat")) (map withPatternMatch patternCons))

  return [
    -- SigD toFoilPatternT (ForallT [PlainTV n SpecifiedSpec, PlainTV l SpecifiedSpec] []
    -- (AppT (AppT ArrowT
    --   ( AppT (AppT (ConT ''Foil.NameBinder) (VarT n)) (VarT l))) -- NameBinder n l
    -- (AppT (AppT ArrowT
    --   (ConT patternT)) -- Pattern
    --   (AppT (AppT (ConT foilPatternT) (VarT n)) (VarT l))) -- FoilScopedTerm n
    -- ))
    -- , FunD toFoilPatternT [Clause [VarP (mkName "binder")] toFoilPatternBody []]

    -- , 
    SigD toFoilScopedT (ForallT [PlainTV n SpecifiedSpec] [AppT (ConT (mkName "Distinct")) (VarT n)]
    (AppT (AppT ArrowT
      ( AppT (AppT ArrowT (ConT nameT)) (AppT (ConT ''Foil.Name) (VarT n)))) -- (VarIdent -> Name n)
    (AppT (AppT ArrowT
      (ParensT (AppT (ConT (mkName "Scope")) (VarT n)))) -- Scope n
    (AppT (AppT ArrowT
       (ConT scopeT)) -- ScopedTerm
      (ParensT (AppT (ConT foilScopeT) (VarT n)))) -- FoilScopedTerm n
    )))
    , FunD toFoilScopedT [Clause [VarP (mkName "toName"), VarP (mkName "scope")] toFoilScopedBody []]

    -- #TODO: FIX mkNamev "t1" - make it more general
    , SigD withPatternT (ForallT [PlainTV n SpecifiedSpec, PlainTV (mkName "r") SpecifiedSpec] [AppT (ConT (mkName "Distinct")) (VarT n)]
    (AppT (AppT ArrowT
      ( AppT (AppT ArrowT (ConT nameT)) (AppT (ConT ''Foil.Name) (VarT n)))) --(VarIdent -> Name n) 
    (AppT (AppT ArrowT
      (ParensT (AppT (ConT (mkName "Scope")) (VarT n)))) -- Scope n
    (AppT (AppT ArrowT
       (ConT patternT)) -- Pattern
    (AppT (AppT ArrowT
      (ForallT [PlainTV l SpecifiedSpec, PlainTV (mkName "t1") SpecifiedSpec] [AppT (ConT (mkName "Distinct")) (VarT l)]  -- forall l. Distinct l
        (AppT (AppT ArrowT
          (ParensT (foldl AppT (ConT foilPatternT) [VarT n, VarT (mkName "t1"), VarT l]))) -- FoilPattern n l
        (AppT (AppT ArrowT
          (ParensT (AppT (AppT ArrowT (ConT nameT)) (AppT (ConT ''Foil.Name) (VarT l))))) -- (VarIdent -> Name l)
        (AppT (AppT ArrowT
          (AppT (ConT (mkName "Scope")) (VarT l))) -- Scope l
          (VarT (mkName "r"))))))) -- r
      (VarT (mkName "r"))
    )))))
    , FunD withPatternT [Clause [VarP (mkName "toName"), VarP (mkName "scope"), VarP (mkName "pat"), VarP (mkName "cont")] withPatternBody []]


    , SigD toFoilTermT (ForallT [PlainTV n SpecifiedSpec] [AppT (ConT (mkName "Distinct")) (VarT n)]
    (AppT (AppT ArrowT
      ( AppT (AppT ArrowT (ConT nameT)) (AppT (ConT ''Foil.Name) (VarT n)))) -- (VarIdent -> Name n)
    (AppT (AppT ArrowT
      (ParensT (AppT (ConT (mkName "Scope")) (VarT n)))) -- Scope n
    (AppT (AppT ArrowT
       (ConT termT)) -- Term
      (ParensT (AppT (ConT foilTermT) (VarT n)))) -- FoilTerm n
    )))
    , FunD toFoilTermT [Clause [VarP (mkName "toName"), VarP (mkName "scope")] toFoilTBody []]
    ]
  where
    foilTermT = mkName ("Foil" ++ nameBase termT)
    foilScopeT = mkName ("Foil" ++ nameBase scopeT)
    foilPatternT = mkName ("Foil" ++ nameBase patternT)

    toFoilTermT = mkName ("toFoil" ++ nameBase termT)
    toFoilPatternT = mkName ("toFoil" ++ nameBase patternT)
    toFoilScopedT = mkName ("toFoil" ++ nameBase scopeT)
    withPatternT = mkName "withPattern"

    toFoilScopedMatch :: Con -> Match
    toFoilScopedMatch (NormalC conName params) =
      Match matchPat (matchBody conTypes matchPat) []

      where
        matchPat = ConP conName [] (toPats 0 conTypes)
        conTypes = map snd params

        toPats :: Int -> [Type] -> [Pat]
        toPats _ [] = []
        toPats n ((ConT tyName):types)
          | tyName == nameT = VarP (mkName $ "varName" ++ show n):toPats (n+1) types
          | tyName == patternT = VarP (mkName "pat"):toPats (n+1) types
          | tyName == scopeT = VarP (mkName "scopedTerm"):toPats (n+1) types
          | tyName == termT = VarP (mkName $ "term" ++ show n):toPats (n+1) types
          | otherwise = VarP (mkName ("x" ++ show n)):toPats (n+1) types

        matchBody :: [Type] -> Pat -> Body
        matchBody matchTypes (ConP name _ matchParams) =
          NormalB (foldl AppE (ConE $ mkName ("Foil" ++ nameBase name)) (zipWith toExpr matchTypes matchParams))

          where
            toExpr :: Type -> Pat -> Exp
            toExpr (ConT tyName) (VarP patName)
              | tyName == termT = AppE (AppE (AppE (VarE toFoilTermT) (VarE (mkName "toName"))) (VarE (mkName "scope"))) (VarE patName)
              | otherwise = VarE patName

    toFoilPatternMatch :: Con -> Match
    toFoilPatternMatch (NormalC conName params) =
      Match matchPat (matchBody conTypes matchPat) []

      where
        matchPat = ConP conName [] (toPats 0 conTypes)
        conTypes = map snd params

        toPats :: Int -> [Type] -> [Pat]
        toPats _ [] = []
        toPats n ((ConT tyName):types)
          | tyName == nameT = VarP (mkName $ "varName" ++ show n):toPats (n+1) types
          | tyName == patternT = VarP (mkName "pat"):toPats (n+1) types
          | tyName == scopeT = VarP (mkName "scopedTerm"):toPats (n+1) types
          | tyName == termT = VarP (mkName $ "term" ++ show n):toPats (n+1) types
          | otherwise = VarP (mkName ("x" ++ show n)):toPats (n+1) types

        matchBody :: [Type] -> Pat -> Body
        matchBody matchTypes (ConP name _ matchParams) = NormalB
          (foldl AppE (ConE (mkName ("Foil" ++ nameBase name)))
            (zipWith3 toExpr matchTypes matchParams binderIndexes))

          where
            binderIndexes = typesToBinderIndexes matchTypes 0
            toExpr :: Type -> Pat -> Int -> Exp
            -- toExpr _ WildP = VarE (mkName "binder")
            toExpr (ConT tyName) (VarP patName) indx
              | tyName == nameT = VarE (mkName ("binder" ++ show indx))
              | otherwise = VarE patName
            
            typesToBinderIndexes :: [Type] -> Int -> [Int]
            typesToBinderIndexes [] _ = []
            typesToBinderIndexes ((ConT tyName):ts) n 
              | tyName == nameT = n : typesToBinderIndexes ts (n+1)
              | otherwise = n : typesToBinderIndexes ts n

    withPatternMatch :: Con -> Match
    withPatternMatch (NormalC conName params) =
      Match matchPat (NormalB body) []

      where
        body
         | countTerm conTypes > 0 = AppE (AppE (VarE 'Foil.withFresh) (VarE (mkName "scope"))) (withFreshPreLamPat 0 (countTerm conTypes - 1))
         | otherwise = LetE [decl] (AppE (AppE (AppE (VarE (mkName "cont")) (VarE (mkName "pat'"))) (VarE (mkName "toName"))) (VarE (mkName "scope")))
            where
              decl = ValD (VarP (mkName "pat'")) (NormalB (foldl AppE (ConE (mkName ("Foil" ++ nameBase conName))) ((\ (ConP _ _ conParams) -> map (\(VarP x) -> VarE x) conParams) matchPat))) []

              withFreshPreLamPat :: Int -> Int -> Exp
              withFreshPreLamPat n lastN 
                | n < lastN = LamE [VarP (mkName ("binder" ++ show n))]
                  (LetE [
                      ValD (VarP (mkName ("scope" ++ show n))) (NormalB (foldl AppE (VarE 'Foil.extendScope) [VarE (mkName ("binder" ++ show n)), VarE (mkName ("scope" ++ (if n > 0 then (show $ n-1) else "")))])) [],
                      FunD (mkName ("toName" ++ show n))
                        [Clause [VarP (mkName "x")]
                          (GuardedB [
                            (NormalG (AppE (AppE (VarE (mkName "==")) (VarE (mkName "x"))) (VarE (mkName ("varName" ++ show n)))), AppE (VarE (mkName "nameOf")) (VarE (mkName ("binder" ++ show n)))),
                            (NormalG (VarE (mkName "otherwise")), AppE (VarE 'Foil.sink) (AppE (VarE (mkName ("toName" ++ (if n > 0 then (show $ n-1) else "")))) (VarE (mkName "x"))))
                          ]) []]
                    ]
                      (AppE (AppE (VarE 'Foil.withFresh) (VarE (mkName ("scope" ++ show n)))) (withFreshPreLamPat (n+1) lastN)))
                | otherwise = LamE [VarP (mkName ("binder" ++ show n))]
                  (LetE [
                      ValD (VarP (mkName "scope'")) (NormalB (foldl AppE (VarE 'Foil.extendScope) [VarE (mkName ("binder" ++ show n)), VarE (mkName ("scope" ++ (if n > 0 then (show $ n-1) else "")))])) [],
                      FunD (mkName "toName'")
                        [Clause [VarP (mkName "x")]
                          (GuardedB [
                            (NormalG (AppE (AppE (VarE (mkName "==")) (VarE (mkName "x"))) (VarE (mkName ("varName" ++ show n)))), AppE (VarE (mkName "nameOf")) (VarE (mkName ("binder" ++ show n)))),
                            (NormalG (VarE (mkName "otherwise")), AppE (VarE 'Foil.sink) (AppE (VarE (mkName ("toName" ++ (if n > 0 then (show $ n-1) else "")))) (VarE (mkName "x"))))
                          ]) []],
                      ValD (VarP (mkName "pat'")) (NormalB (foldl AppE (ConE (mkName ("Foil" ++ nameBase conName))) (bindersList 0 (countTerm conTypes)))) []
                    ]
                      (AppE (AppE (AppE (VarE (mkName "cont")) (VarE (mkName "pat'"))) (VarE (mkName "toName'"))) (VarE (mkName "scope'"))))

              bindersList :: Int -> Int -> [Exp]
              bindersList n lastN
                | n < lastN = VarE (mkName ("binder" ++ show n)) : bindersList (n+1) lastN
                | otherwise = []


        matchPat = ConP conName [] (toPats 0 conTypes)
        conTypes = map snd params

        toPats :: Int -> [Type] -> [Pat]
        toPats _ [] = []
        toPats n ((ConT tyName):types)
          | tyName == nameT = VarP (mkName $ "varName" ++ show n):toPats (n+1) types
          | tyName == patternT = VarP (mkName "pat"):toPats (n+1) types
          | tyName == scopeT = VarP (mkName "scopedTerm"):toPats (n+1) types
          | tyName == termT = VarP (mkName $ "term" ++ show n):toPats (n+1) types
          | otherwise = VarP (mkName ("x" ++ show n)):toPats (n+1) types

        countTerm :: [Type] -> Int
        countTerm [] = 0
        countTerm ((ConT t):ts)
          | t == nameT = 1 + countTerm ts
          | otherwise = countTerm ts

    toMatchTerm :: Con -> Match
    toMatchTerm (NormalC conName params) =
      Match matchPat (matchBody conTypes matchPat) []

      where
        matchPat = ConP conName [] (toPats 0 conTypes)
        conTypes = map snd params

        toPats :: Int -> [Type] -> [Pat]
        toPats _ [] = []
        toPats n ((ConT tyName):types)
          | tyName == nameT = VarP (mkName $ "varName" ++ show n):toPats (n+1) types
          | tyName == patternT = VarP (mkName "pat"):toPats (n+1) types
          | tyName == scopeT = VarP (mkName "scopedTerm"):toPats (n+1) types
          | tyName == termT = VarP (mkName $ "term" ++ show n):toPats (n+1) types
          | otherwise = VarP (mkName ("x" ++ show n)):toPats (n+1) types

        matchBody :: [Type] -> Pat -> Body
        matchBody matchTypes (ConP name _ matchParams) =
          NormalB constr

          where
            constr = if checkPatScope matchTypes False
              then toExprScopeExt
              else foldl AppE (ConE $ mkName ("Foil" ++ nameBase name)) (zipWith toExprWithoutScope matchTypes matchParams)


            checkPatScope :: [Type] -> Bool -> Bool
            checkPatScope [] _ = False
            checkPatScope ((ConT tyName):rest) patFound
              | tyName == patternT = checkPatScope rest True
              | tyName == scopeT && patFound = True
              | otherwise = checkPatScope rest patFound


            toExprWithoutScope :: Type -> Pat -> Exp
            toExprWithoutScope (ConT tyName) (VarP patName)
              | tyName == nameT = AppE (VarE $ mkName "toName") (VarE patName)
              | tyName == termT = AppE (AppE (AppE (VarE toFoilTermT) (VarE (mkName "toName"))) (VarE (mkName "scope"))) (VarE patName)
              | otherwise = VarE patName

            toExprScopeExt = foldl AppE (VarE withPatternT) [VarE (mkName "toName"), VarE (mkName "scope"), VarE (fromJust (findPatternName matchTypes matchParams)), lamCase]
              where
                lamCase = LamE [VarP pat', VarP (mkName "toName'"), VarP (mkName "scope'")]
                  (foldl AppE (ConE (mkName ("Foil" ++ nameBase name))) (zipWith _toExpr matchTypes matchParams))

                pat' = mkName (nameBase (fromJust (findPatternName matchTypes matchParams)) ++ "'")

                findPatternName :: [Type] -> [Pat] -> Maybe Name
                findPatternName [] [] = Nothing
                findPatternName  ((ConT tyName):_) ((VarP varName):_)
                  | tyName == patternT = Just varName
                findPatternName (_:restT) (_:restP) = findPatternName restT restP

                _toExpr :: Type -> Pat -> Exp
                _toExpr (ConT tyName) (VarP patName)
                  | tyName == termT = foldl AppE (VarE toFoilTermT) [VarE (mkName "toName"), VarE (mkName "scope"), VarE patName]
                  | tyName == nameT = VarE patName
                  | tyName == patternT = VarE (mkName (nameBase patName ++ "'"))
                  | tyName == scopeT = foldl AppE (VarE toFoilScopedT) [VarE (mkName "toName'"), VarE (mkName "scope'"), VarE patName]
                  | otherwise = VarE patName