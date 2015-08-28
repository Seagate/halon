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
) where

import HA.ResourceGraph

import Control.Distributed.Process.Closure
import Control.Monad (join)

import Data.List (intercalate)

import Language.Haskell.TH

mkDicts :: [Name] -- ^ Resources
        -> [(Name, Name, Name)] -- ^ Relations
        -> Q [Dec] -- ^ Decls
mkDicts res rel = do
  resD <- join <$> mapM mkResourceDict res
  relD <- join <$> mapM mkRelationDict rel
  return $ resD ++ relD

mkResRel :: [Name] -- ^ Resources
         -> [(Name, Name, Name)] -- ^ Relations
         -> [Name] -- ^ Any additional functions to add to `remotable`
         -> Q [Dec] -- ^ Decls
mkResRel res rel othernames = do
  (resN, resD) <- fmap join . unzip <$> mapM mkResource res
  (relN, relD) <- fmap join . unzip <$> mapM mkRelation rel
  remD <- remotable (resN ++ relN ++ othernames)
  return $ remD ++ resD ++ relD

-- | Make the given type into a @Resource@
mkResource :: Name -- ^ Type name of resource
           -> Q (Name, [Dec]) -- ^ (Function to include in remotable, decls)
mkResource res = do
    inst <- instanceD (cxt []) dictType [instDec]
    return (dictName, [inst])
  where
    dictType = conT ''Resource `appT` conT res
    instDec = funD 'resourceDict [clause [] (normalB $ mkStatic dictName) []]
    dictName = mkResourceName res

-- | Make the given (from, rel, to) tuple into a @Relation@
mkRelation :: (Name, Name, Name)
           -> Q (Name, [Dec])
mkRelation r@(from, by, to) = do
    inst <- instanceD (cxt []) dictType [instDec]
    return (dictName, [inst])
  where
    dictType = conT ''Relation `appT` conT by `appT` conT from `appT` conT to
    instDec = funD 'relationDict [clause [] (normalB $ mkStatic dictName) []]
    dictName = mkRelationName r

mkResourceDict :: Name -> Q [Dec]
mkResourceDict res = do

    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictName = mkResourceName res
    dictType = conT ''Resource `appT` conT res

mkRelationDict :: (Name, Name, Name) -> Q [Dec]
mkRelationDict r@(from, by, to) = do
    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictType = conT ''Relation `appT` conT by `appT` conT from `appT` conT to
    dictName = mkRelationName r

mkResourceName :: Name -> Name
mkResourceName res = mkName $ "resourceDict_" ++ nameBase res

mkRelationName :: (Name, Name, Name) -> Name
mkRelationName (from, by, to) = mkName $ "relationDict"
  ++ intercalate "_" [nameBase from, nameBase by, nameBase to]


