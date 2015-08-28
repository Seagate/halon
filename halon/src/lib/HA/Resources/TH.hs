{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Template Haskell code to generate all the necessary boilerplate
-- for resources and relations.

module HA.Resources.TH (
    mkDicts
  , mkResRel
  , mkResource
  , mkRelation
  , conT -- ^ Exported for convenience
) where

import HA.ResourceGraph

import Control.Distributed.Process.Closure
import Control.Monad (join)

import Data.List (intercalate)

import Language.Haskell.TH

mkDicts :: [TypeQ] -- ^ Resources
        -> [(TypeQ, TypeQ, TypeQ)] -- ^ Relations
        -> Q [Dec] -- ^ Decls
mkDicts res rel = do
  resD <- join <$> mapM mkResourceDict res
  relD <- join <$> mapM mkRelationDict rel
  return $ resD ++ relD

mkResRel :: [TypeQ] -- ^ Resources
         -> [(TypeQ, TypeQ, TypeQ)] -- ^ Relations
         -> [Name] -- ^ Any additional functions to add to `remotable`
         -> Q [Dec] -- ^ Decls
mkResRel res rel othernames = do
  (resN, resD) <- (fmap join . unzip) <$> mapM mkResource res
  (relN, relD) <- (fmap join . unzip) <$> mapM mkRelation rel
  remD <- remotable (resN ++ relN ++ othernames)
  return $ remD ++ resD ++ relD

-- | Make the given type into a @Resource@
mkResource :: TypeQ -- ^ Type name of resource
           -> Q (Name, [Dec]) -- ^ (Function to include in remotable, decls)
mkResource res = do
    dictName <- mkResourceName res
    inst <- instanceD (cxt []) dictType [instDec dictName]
    return (dictName, [inst])
  where
    dictType = conT ''Resource `appT` res
    instDec dn = funD 'resourceDict [clause [] (normalB $ mkStatic dn) []]

-- | Make the given (from, rel, to) tuple into a @Relation@
mkRelation :: (TypeQ, TypeQ, TypeQ)
           -> Q (Name, [Dec])
mkRelation r@(from, by, to) = do
    dictName <- mkRelationName r
    inst <- instanceD (cxt []) dictType [instDec dictName]
    return (dictName, [inst])
  where
    dictType = conT ''Relation `appT` by `appT` from `appT` to
    instDec dn = funD 'relationDict [clause [] (normalB $ mkStatic dn) []]


mkResourceDict :: TypeQ -> Q [Dec]
mkResourceDict res = do
    dictName <- mkResourceName res
    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictType = conT ''Resource `appT` res

mkRelationDict :: (TypeQ, TypeQ, TypeQ) -> Q [Dec]
mkRelationDict r@(from, by, to) = do
    dictName <- mkRelationName r
    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictType = conT ''Relation `appT` by `appT` from `appT` to

mkResourceName :: TypeQ -> Q Name
mkResourceName res = do
  resN <- getName res
  return . mkName $ "resourceDict_" ++ resN

mkRelationName :: (TypeQ, TypeQ, TypeQ) -> Q Name
mkRelationName (from, by, to) = do
  fn <- getName from
  bn <- getName by
  tn <- getName to
  return . mkName $ "relationDict" ++ intercalate "_" [fn, bn, tn]

getName :: TypeQ -> Q String
getName typ = typ >>= return . go
  where
    go :: Type -> String
    go (AppT t1 t2) = go t1 ++ "_" ++ go t2
    go (ConT name) = nameBase name
    go _ = undefined


