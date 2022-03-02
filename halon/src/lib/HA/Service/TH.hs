{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.
module HA.Service.TH
  ( generateDicts
  , deriveService
  , StorageIndex(..)
  , serviceStorageIndex
  , module HA.Resources.TH
  ) where

import Language.Haskell.TH

import Control.Distributed.Process.Closure
import Control.Distributed.Static
import Data.Proxy
import Data.Rank1Dynamic

import HA.ResourceGraph
import HA.Resources
import HA.Resources.TH
import HA.Service

-- XXX: document how to use this module
-- XXX: rewrite code so only one function will be need to be called

serviceStorageIndex :: Name
             -> String
             -> Q [Dec]
serviceStorageIndex n s =
  [d| instance StorageIndex (Service $(conT n)) where typeKey _ = $(mkUUID s) |]

-- @
--
-- @$(generateDicts ''N)@ will produce
--
-- @
-- storageDictSupportsClusterService :: Dict (StorageRelation Supports Cluster (Service N))
-- storageDictSupportsClusterService = Dict
--
-- relationDictSupportsClusterService_x :: Dict (Relation Supports Cluster (Service N))
-- relationDictSupportsClusterService_x = Dict
--
-- resourceDictServiceInfo :: Dict (Resource N)
-- resourceDictServiceInfo = Dict
--
-- storageDictServiceInfo_x :: Dict (StorageResource N)
-- storageDictServiceInfo_x = Dict
--
-- resourceDictService_x :: Dict (Resource (Service N)
-- resourceDictService_x = Dict
--
-- storageDictService :: Dict (StorageResource N)
-- storageDictService = Dict
--
-- serializableDict_x :: SerializableDict N
-- serializableDict_x = SerializableDict
--
-- configDict_x :: Dict (Configuration N)
-- configDict_x = Dict
-- @
generateDicts :: Name -> Q [Dec]
generateDicts n = do
    let namSCS = mkName "relationDictSupportsClusterService"
        relSCS = conT ''Relation `appT`
                 conT ''Supports `appT`
                 conT ''Cluster  `appT`
                 (conT ''Service `appT` conT n)
    funSCS <- funD namSCS [clause [] (normalB $ conE 'Dict) []]
    sigSCS <- sigD namSCS (conT ''Dict `appT` relSCS)

    let snamSCS = mkName "storageDictSupportsClusterService"
        srelSCS = conT ''StorageRelation `appT`
                  conT ''Supports `appT`
                  conT ''Cluster  `appT`
                  (conT ''Service `appT` conT n)
    sfunSCS <- funD snamSCS [clause [] (normalB $ conE 'Dict) []]
    ssigSCS <- sigD snamSCS (conT ''Dict `appT` srelSCS)

    let namRA = mkName "resourceDictServiceInfo"
        rrRA  = conT ''Resource `appT` conT n
    funRA <- funD namRA [clause [] (normalB $ conE 'Dict) []]
    sigRA <- sigD namRA (conT ''Dict `appT` rrRA)

    let snamRA = mkName "storageDictServiceInfo"
        srrRA  = conT ''StorageResource `appT` conT n
    sfunRA <- funD snamRA [clause [] (normalB $ conE 'Dict) []]
    ssigRA <- sigD snamRA (conT ''Dict `appT` srrRA)

    let namRSA = mkName "resourceDictService"
        rrRSA  = conT ''Resource `appT` (conT ''Service `appT` conT n)
    funRSA <- funD namRSA [clause [] (normalB $ conE 'Dict) []]
    sigRSA <- sigD namRSA (conT ''Dict `appT` rrRSA)

    let snamRSA = mkName "storageDictService"
        srrRSA  = conT ''StorageResource `appT` (conT ''Service `appT` conT n)
    sfunRSA <- funD snamRSA [clause [] (normalB $ conE 'Dict) []]
    ssigRSA <- sigD snamRSA (conT ''Dict `appT` srrRSA)

    let namSaDict = mkName "serializableDict"
    funSaDict <- funD namSaDict [clause [] (normalB $ conE 'SerializableDict) []]
    sigSaDict <- sigD namSaDict (conT ''SerializableDict `appT` conT n)

    let namConfDict = mkName ("configDict" ++ nameBase n)
    funConfDict <- funD namConfDict [clause [] (normalB $ conE 'Dict) []]
    sigConfDict <- sigD namConfDict (conT ''Dict `appT`
                                    (conT ''Configuration `appT` conT n))

    return [ sigSCS
           , funSCS
           , ssigSCS
           , sfunSCS
           , funRA
           , sigRA
           , sfunRA
           , ssigRA
           , sigRSA
           , funRSA
           , ssigRSA
           , sfunRSA
           , sigSaDict
           , funSaDict
           , funConfDict
           , sigConfDict
           ]

-- | Helper function to generate service related boilerplate. This
-- function require deriveService to be called first.
--
-- @deriveService ''N 'nschema [remotables]@
--
-- will produce:
--
-- @
-- instance StorageRelation Supports Cluster (Sevice N) where
--   storageRelationDict = $(mkStatic storageDictSupportsClusterService)
--
-- instance Relation Supports Cluster (Sevice N) where
--   type CardinalityFrom Supports Cluster (Service N) = AtMostOne
--   type CardinalityTo   Supports Cluster (Service N) = AtMostOne
--   relationDict = $(mkStatic relationDictSupportsClusterService_x)
--
-- instance StorageResource N where
--   storageResourceDict = $(mkStatic resourceDictServiceInfo)
--
-- instance Resource N where
--   relationDict = $(mkStatic resourceDictServiceInfo_x)
--
-- instance StorageResource N where
--   storageResourceDict = $(mkStatic storageDictServiceInfo)
--
-- instance Resource (Service N) where
--   relationDict = $(mkStatic resourceDictService_x)
--
-- instance StorageResource (Service N) where
--   storageResourceDict = $(mkStatic storageDictService)
--
-- instance Configuration N where
--   schema = nschema
--   sDict = $(mkStatic serializableDict_x)
--
-- remotable $
--    [ configDict_x, 'serializableDict_x, 'resourceDictService
--    , 'resourceDictServiceInfo, 'relationDictSupportsClusterService
--    ] ++ remotables
-- @
deriveService :: Name   -- ^ Configuration data constructor
              -> Name   -- ^ Schema  function
              -> [Name] -- ^ Functions to add to `remotable`
              -> Q [Dec]
deriveService n nschema othernames = do
    -- Relation Supports Cluster (Service a)
    let namSCS = mkName "relationDictSupportsClusterService"
    let snamSCS = mkName "storageDictSupportsClusterService"
    rSCS <- [d| instance Relation Supports Cluster (Service $(conT n)) where
                  type CardinalityFrom Supports Cluster (Service $(conT n))
                    = 'AtMostOne
                  type CardinalityTo   Supports Cluster (Service $(conT n))
                    = 'AtMostOne
                  relationDict = $(mkStatic namSCS)
                instance StorageRelation Supports Cluster (Service $(conT n)) where
                   storageRelationDict = $(mkStatic snamSCS)
              |]

    -- Resource a
    let namRA = mkName "resourceDictServiceInfo"
        snamRA = mkName "storageDictServiceInfo"
    rRA <- [d| instance Resource $(conT n) where
                 resourceDict = $(mkStatic namRA)
               instance StorageResource $(conT n) where
                 storageResourceDict = $(mkStatic snamRA)
             |]

    -- Resource (Service a)
    let namRSA = mkName "resourceDictService"
        snamRSA = mkName "storageDictService"
    rRSA <- [d| instance Resource ($(conT ''Service) $(conT n)) where
                  resourceDict = $(mkStatic namRSA)
                instance StorageResource ($(conT ''Service) $(conT n)) where
                  storageResourceDict = $(mkStatic snamRSA)
             |]

    -- Configuration a
    let namSaDict = mkName "serializableDict"
    saConf <- instanceD (cxt []) (conT ''Configuration `appT` conT n)
              [ funD 'schema [clause [] (normalB $ varE nschema) []]
              , funD 'sDict [clause [] (normalB $ mkStatic namSaDict) []]
              ]

    -- Dict (Configuration a)
    let namConfDict = mkName ("configDict" ++ nameBase n)
    resT <- [d|
       __resourcesTable :: RemoteTable -> RemoteTable
       __resourcesTable =
          let res rt = case unstatic rt (resourceDict :: Static (Dict (Resource (Service $(conT n))))) of
                Right z -> registerStatic (mkResourceKeyName (Proxy :: Proxy (Service $(conT n))))
                                          (toDynamic (someResourceDict z))
                                          rt
                Left _ -> rt
              sres rt = case unstatic rt (storageResourceDict :: Static (Dict (StorageResource (Service $(conT n))))) of
                Right z -> registerStatic (mkStorageResourceKeyName (Proxy :: Proxy (Service $(conT n))))
                                          (toDynamic (someStorageResourceDict z))
                                          rt
                Left _ -> rt
              rel rt = case unstatic rt (relationDict :: Static (Dict (Relation Supports Cluster (Service $(conT n))))) of
                 Right z -> registerStatic (mkRelationKeyName
                                              ( Proxy :: Proxy Supports
                                              , Proxy :: Proxy Cluster
                                              , Proxy :: Proxy (Service $(conT n))))
                                           (toDynamic (someRelationDict z))
                                           rt
                 Left _ -> rt
              srel rt = case unstatic rt (storageRelationDict :: Static (Dict (StorageRelation Supports Cluster (Service $(conT n))))) of
                 Right z -> registerStatic (mkStorageRelationKeyName
                                              ( Proxy :: Proxy Supports
                                              , Proxy :: Proxy Cluster
                                              , Proxy :: Proxy (Service $(conT n))))
                                         (toDynamic (someStorageRelationDict z))
                                         rt
                 Left _ -> rt
          in res . sres . rel . srel
         |]
    stDecs <- remotable ([ namConfDict
                         , namSaDict
                         , namRSA
                         , snamRSA
                         , namRA
                         , snamRA
                         , namSCS
                         , snamSCS
                         ] ++ othernames)

    let decs = saConf : rSCS ++ rRA ++ rRSA ++ resT

    return (decs ++ stDecs)
