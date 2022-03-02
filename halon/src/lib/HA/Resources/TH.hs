{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Template Haskell code to generate all the necessary boilerplate
-- for resources and relations.

module HA.Resources.TH (
    storageIndex
  , mkUUID
  , mkDicts
  , mkResRel
  , mkResource
  , mkRelation
  , mkResourcesTable
  , mkStorageDicts
  , mkStorageRelation
  , mkStorageRelationName
  , mkStorageResource
  , mkStorageResourceName
  , mkStorageResourceTable
  , Cardinality(..)
    -- generalized versions
  , mkDictsQ
  , mkStorageDictsQ
  , storageIndexQ
  , mkStorageResRelQ
  , mkStorageResourceQ
  , makeResource
  , makeRelation
  , makeStorageResource
  , makeStorageRelation
) where

import HA.ResourceGraph

import Control.Applicative
import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Control.Monad (join)

import Data.List (intercalate)
import Data.Maybe (fromJust)
import Data.Proxy
import Data.Rank1Dynamic
import qualified Data.UUID as UUID

import Language.Haskell.TH

-- | Generate UUID from string in compile time. This method can't fail in runtime.
mkUUID :: String -> ExpQ
mkUUID s =  [e| UUID.fromWords w1 w2 w3 w4 |]
  where u = fromJust (UUID.fromString s)
        (w1,w2,w3,w4) = UUID.toWords u

-- | Generate 'StorageIndex' instance.
storageIndex :: Name -> String -> DecsQ
storageIndex n s =
  [d| instance StorageIndex $(conT n) where typeKey _ = $(mkUUID s) |]

-- | Generate 'StorageIndex' instance for composed types:
--
-- @ storageIndexQ [t| Maybe Int |] "uuid" @
storageIndexQ :: TypeQ -> String -> DecsQ
storageIndexQ type_ s =
  [d| instance StorageIndex $type_ where typeKey _ = $(mkUUID s) |]

mkDicts :: [Name] -- ^ Resources
        -> [(Name, Name, Name)] -- ^ Relations
        -> DecsQ -- ^ Decls
mkDicts res rel = do
  x <- mkDictsQ (liftA2 (,) mkResourceName conT  <$> res)
                (liftA2 (,) mkRelationName conTs <$> rel)
  y <- mkStorageDicts res rel
  return $ x ++ y

-- | 'mkDicsQ' function does not create dictionaries for the storage
-- resources in order to avoid name conflicts.
mkDictsQ :: [(Name, TypeQ)]
         -> [(Name, (TypeQ, TypeQ, TypeQ))]
         -> DecsQ
mkDictsQ res rel = do
  resD <- join <$> mapM (uncurry mkResourceDictQ) res
  relD <- join <$> mapM (uncurry mkRelationDictQ) rel
  return $ resD ++ relD

mkResRel :: [Name] -- ^ Resources
         -> [(Name, Cardinality, Name, Cardinality, Name)] -- ^ Relations
         -> [Name] -- ^ Any additional functions to add to `remotable`
         -> DecsQ -- ^ Decls
mkResRel res rel othernames = do
  (resN, resD) <- fmap join . unzip <$> mapM mkResource res
  (relN, relD) <- fmap join . unzip <$> mapM mkRelation rel
  (sresN, sresD) <- fmap join . unzip <$> mapM mkStorageResource res
  (srelN, srelD) <- fmap join . unzip <$> mapM (\(r,_,a,_,b) -> mkStorageRelation (r,a,b)) rel
  remD <- remotable (sresN ++ resN ++ srelN ++ relN ++ othernames)
  resTable <- mkResourcesTable res (map (\(r,_,a,_,b) -> (r,a,b)) rel)
  return $ remD ++ sresD ++ srelD ++ resD ++ relD ++ resTable

mkStorageDicts :: [Name] -> [(Name, Name, Name)] -> DecsQ
mkStorageDicts res rel = do
  mkStorageDictsQ (liftA2 (,) mkStorageResourceName conT  <$> res)
                  (liftA2 (,) mkStorageRelationName conTs <$> rel)

mkStorageDictsQ :: [(Name, TypeQ)]
                -> [(Name, (TypeQ, TypeQ, TypeQ))]
                -> DecsQ
mkStorageDictsQ res rel = do
  resD <- join <$> mapM (uncurry mkStorageResourceDictQ) res
  relD <- join <$> mapM (uncurry mkStorageRelationDictQ) rel
  return $ resD ++ relD

mkStorageResRelQ :: [(Name, TypeQ)]
                 -> [(Name, (TypeQ, TypeQ, TypeQ))]
                 -> DecsQ
mkStorageResRelQ res rel = do
  resD <- mapM (uncurry mkStorageResourceQ) res
  relD <- join <$> mapM (uncurry mkStorageRelationQ) rel
  return $ resD ++ relD

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

-- | Make the given type info a @StorageResource@
mkStorageResource :: Name -- ^ Type name of the resource
                  -> Q (Name, [Dec])
mkStorageResource res = do
  d <- mkStorageResourceQ (mkStorageResourceName res) (conT res)
  return (mkStorageResourceName res, [d])

mkStorageResourceQ :: Name -> TypeQ -> DecQ
mkStorageResourceQ dictName res = instanceD (cxt []) dictType [instDec]
  where
    dictType = conT ''StorageResource `appT` res
    instDec = funD 'storageResourceDict [clause [] (normalB $ mkStatic dictName) []]

mkStorageRelation :: (Name, Name, Name) -> Q (Name, [Dec])
mkStorageRelation r@(a,b,c) =
  (sdictName,) <$> mkStorageRelationQ sdictName (conT a, conT b, conT c)
  where sdictName = mkStorageRelationName r

-- | Make the given type info a
mkStorageRelationQ :: Name
                  -> (TypeQ, TypeQ, TypeQ)
                  -> DecsQ
mkStorageRelationQ sdictName (from, by, to) = do
    [d| instance StorageRelation $by $from $to where
          storageRelationDict = $(mkStatic sdictName)
      |]

-- | Make the given (from, rel, to) tuple into a @Relation@
mkRelation :: (Name, Cardinality, Name, Cardinality, Name)
           -> Q (Name, [Dec])
mkRelation (from, cfrom, by, cto, to) = do
    inst <- [d| instance  Relation $(conT by) $(conT from) $(conT to) where
                  type CardinalityFrom $(conT by) $(conT from) $(conT to)
                    = $(liftCardinalityT cfrom)
                  type CardinalityTo $(conT by) $(conT from) $(conT to)
                    = $(liftCardinalityT cto)
                  relationDict = $(mkStatic dictName)
              |]
    return (dictName, inst)
  where
    dictName = mkRelationName (from, by, to)
    liftCardinalityT AtMostOne = conT 'AtMostOne
    liftCardinalityT Unbounded = conT 'Unbounded

mkResourceDictQ :: Name -> TypeQ -> DecsQ
mkResourceDictQ dictName res = do
    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictType = conT ''Resource `appT` res

mkRelationDictQ :: Name -> (TypeQ, TypeQ, TypeQ) -> DecsQ
mkRelationDictQ dictName (from, by, to) = do
    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictType = conT ''Relation `appT` by `appT` from `appT` to

-- | Create a dictionary for StorageReosource.
mkStorageResourceDictQ :: Name -> TypeQ -> DecsQ
mkStorageResourceDictQ dictName res =  do
    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictType = conT ''StorageResource `appT` res

-- | Create a dictionary for StorageRelation.
mkStorageRelationDictQ :: Name -> (TypeQ, TypeQ, TypeQ) -> DecsQ
mkStorageRelationDictQ dictName (from, by, to) = do
    dictSig <- sigD dictName (conT ''Dict `appT` dictType)
    dictVal <- valD (varP dictName) (normalB $ conE 'Dict) []
    return [dictSig, dictVal]
  where
    dictType = conT ''StorageRelation `appT` by `appT` from `appT` to

mkResourceName :: Name -> Name
mkResourceName res = mkName $ "resourceDict_" ++ nameBase res

mkStorageResourceName :: Name -> Name
mkStorageResourceName res = mkName $ "storageResourceDict_" ++ nameBase res

mkRelationName :: (Name, Name, Name) -> Name
mkRelationName (from, by, to) = mkName $ "relationDict"
  ++ intercalate "_" [nameBase from, nameBase by, nameBase to]

mkStorageRelationName :: (Name, Name, Name) -> Name
mkStorageRelationName (from, by, to) = mkName $ "storageRelationDict"
  ++ intercalate "_" [nameBase from, nameBase by, nameBase to]

conTs :: (Name, Name, Name) -> (TypeQ, TypeQ, TypeQ)
conTs (a, b, c) = (conT a, conT b, conT c)

mkResourcesTable :: [Name] -> [(Name, Name, Name)] -> DecsQ
mkResourcesTable names rels =
    mkResourceTableQ (conT <$> names) (conTs <$> rels)

mkStorageResourceTable :: [Name] -> [(Name, Name, Name)] -> DecsQ
mkStorageResourceTable names rels =
    mkStorageResourceTableQ (conT <$> names) (conTs <$> rels)

mkResourceTableQ :: [TypeQ] -> [(TypeQ, TypeQ, TypeQ)] -> DecsQ
mkResourceTableQ names rels = do
    let m = mkName "__resourcesTable"
        is = map makeResource names
        rs = map (\(a, r, b) -> makeRelation a r b) rels
    sequence [ sigD m [t| RemoteTable -> RemoteTable |]
             , funD m [clause [] (normalB (compose (is ++ rs))) []]
             ]

mkStorageResourceTableQ :: [TypeQ] -> [(TypeQ, TypeQ, TypeQ)] -> DecsQ
mkStorageResourceTableQ names rels = do
    let m = mkName "__resourcesTable"
        ls = map makeStorageResource names
        ds = map (\(a, r, b) -> makeStorageRelation a r b) rels
    sequence [ sigD m [t| RemoteTable -> RemoteTable |]
             , funD m [clause [] (normalB (compose (ls ++ ds))) []]
             ]

-- | Composition of the ExpQ, required to make TH not consume
-- terabytes of memory.
compose :: [ExpQ] -> ExpQ
compose [] = [| id |]
compose [e] = e
compose (e:es) = [| $e . $(compose es) |]

genTableUpdate :: ExpQ -> ExpQ -> ExpQ -> ExpQ
genTableUpdate dict key som =
  [e| \rt -> case unstatic rt $dict of
               Right z -> registerStatic $key (toDynamic ($som z)) rt
               Left _ -> rt
    |]

-- | Create resource.
makeResource :: TypeQ -> ExpQ
makeResource x = [e| $f . $(makeStorageResource x) |]
  where
    f = genTableUpdate [e| resourceDict :: Static (Dict (Resource $x)) |]
                       [e| mkResourceKeyName (Proxy :: Proxy $x) |]
                       [e| someResourceDict |]

-- | Create relation.
makeRelation :: TypeQ -> TypeQ -> TypeQ -> ExpQ
makeRelation a r b  = [e| $f . $(makeStorageRelation a r b) |]
  where
    f = genTableUpdate [e| relationDict :: Static (Dict (Relation $r $a $b)) |]
                       [e| mkRelationKeyName (Proxy :: Proxy $r, Proxy :: Proxy $a, Proxy :: Proxy $b) |]
                       [e| someRelationDict |]

makeStorageRelation :: TypeQ -> TypeQ -> TypeQ -> ExpQ
makeStorageRelation a r b =
  genTableUpdate [e| storageRelationDict :: Static (Dict (StorageRelation $r $a $b)) |]
                 [e| mkStorageRelationKeyName (Proxy :: Proxy $r, Proxy :: Proxy $a, Proxy :: Proxy $b) |]
                 [e| someStorageRelationDict |]

makeStorageResource :: TypeQ -> ExpQ
makeStorageResource x =
  genTableUpdate [e| storageResourceDict :: Static (Dict (StorageResource $x))|]
                 [e| mkStorageResourceKeyName (Proxy :: Proxy $x)|]
                 [e| someStorageResourceDict |]
