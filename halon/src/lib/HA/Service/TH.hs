{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.
module HA.Service.TH
  ( generateDicts
  , deriveService
  ) where

import Language.Haskell.TH

import Control.Distributed.Process.Closure

import HA.ResourceGraph
import HA.Resources
import HA.Service

-- XXX: document how to use this module
-- XXX: rewrite code so only one function will be need to be called

-- @
--
-- @$(generateDicts ''N)@ will produce
--
-- @
-- relationDictSupportsClusterService_x :: Dict (Relation Supports Cluster (Service N))
-- relationDictSupportsClusterService_x = Dict
--
-- resourceDictServiceInfo_x :: Dict (Resource N)
-- resourceDictServiceInfo_x = Dict
--
-- resourceDictService_x :: Dict (Resource (Service N)
-- resourceDictService_x = Dict
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

    let namRA = mkName "resourceDictServiceInfo"
        rrRA  = conT ''Resource `appT` conT n
    funRA <- funD namRA [clause [] (normalB $ conE 'Dict) []]
    sigRA <- sigD namRA (conT ''Dict `appT` rrRA)

    let namRSA = mkName "resourceDictService"
        rrRSA  = conT ''Resource `appT` (conT ''Service `appT` conT n)
    funRSA <- funD namRSA [clause [] (normalB $ conE 'Dict) []]
    sigRSA <- sigD namRSA (conT ''Dict `appT` rrRSA)


    let namSaDict = mkName "serializableDict"
    funSaDict <- funD namSaDict [clause [] (normalB $ conE 'SerializableDict) []]
    sigSaDict <- sigD namSaDict (conT ''SerializableDict `appT` conT n)

    let namConfDict = mkName ("configDict" ++ nameBase n)
    funConfDict <- funD namConfDict [clause [] (normalB $ conE 'Dict) []]
    sigConfDict <- sigD namConfDict (conT ''Dict `appT`
                                    (conT ''Configuration `appT` conT n))

    return [ sigSCS
           , funSCS
           , funRA
           , sigRA
           , sigRSA
           , funRSA
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
-- instance Relation (Supports Cluster Sevice N) where
--   relationDict = $(mkStatic relationDictSupportsClusterService_x)
--
-- instance Resource N where
--   relationDict = $(mkStatic resourceDictServiceInfo_x)
--
-- instance Resource (Service N) where
--   relationDict = $(mkStatic resourceDictService_x)
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
        relSCS = conT ''Relation `appT`
                 conT ''Supports `appT`
                 conT ''Cluster  `appT`
                 (conT ''Service `appT` conT n)
    rSCS <- instanceD (cxt []) relSCS
            [ funD 'relationDict [clause [] (normalB $ mkStatic namSCS) []]]

    -- Resource a
    let namRA = mkName "resourceDictServiceInfo"
        rrRA  = conT ''Resource `appT` conT n
    rRA <- instanceD (cxt []) rrRA
           [ funD 'resourceDict [clause [] (normalB $ mkStatic namRA) []]]

    -- Resource (Service a)
    let namRSA = mkName "resourceDictService"
        rrRSA  = conT ''Resource `appT` (conT ''Service `appT` conT n)
    rRSA <- instanceD (cxt []) rrRSA
            [ funD 'resourceDict [clause [] (normalB $ mkStatic namRSA) []]]


    -- Configuration a
    let namSaDict = mkName "serializableDict"
    saConf <- instanceD (cxt []) (conT ''Configuration `appT` conT n)
              [ funD 'schema [clause [] (normalB $ varE nschema) []]
              , funD 'sDict [clause [] (normalB $ mkStatic namSaDict) []]
              ]

    -- Dict (Configuration a)
    let namConfDict = mkName ("configDict" ++ nameBase n)

    stDecs <- remotable ([ namConfDict
                         , namSaDict
                         , namRSA
                         , namRA
                         , namSCS
                         ] ++ othernames)

    let decs = [ rSCS
               , rRA
               , rRSA
               , saConf
               ]

    return (decs ++ stDecs)
