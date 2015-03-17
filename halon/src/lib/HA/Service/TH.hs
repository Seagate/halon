{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Services are uniquely named on a given node by a string. For example
-- "ioservice" may identify the IO service running on a node.
module HA.Service.TH where

import Language.Haskell.TH

import Control.Distributed.Process.Closure

import HA.ResourceGraph
import HA.Resources
import HA.Service

generateDicts :: Name -> Q [Dec]
generateDicts n = do
    let namSCS = mkName "relationDictSupportsClusterService"
        relSCS = conT ''Relation `appT`
                 conT ''Supports `appT`
                 conT ''Cluster  `appT`
                 (conT ''Service `appT` conT n)
    funSCS <- funD namSCS [clause [] (normalB $ conE 'Dict) []]
    sigSCS <- sigD namSCS (conT ''Dict `appT` relSCS)

    let namRNS = mkName "relationDictHasNodeServiceProcess"
        relRNS = conT ''Relation `appT`
                 conT ''Runs `appT`
                 conT ''Node  `appT`
                 (conT ''ServiceProcess `appT` conT n)
    funRNS <- funD namRNS [clause [] (normalB $ conE 'Dict) []]
    sigRNS <- sigD namRNS (conT ''Dict `appT` relRNS)


    let namISS = mkName "relationDictInstanceOfServiceServiceProcess"
        relISS = conT ''Relation                `appT`
                 conT ''InstanceOf              `appT`
                 (conT ''Service `appT` conT n) `appT`
                 (conT ''ServiceProcess `appT` conT n)
    funISS <- funD namISS [clause [] (normalB $ conE 'Dict) []]
    sigISS <- sigD namISS (conT ''Dict `appT` relISS)

    let namOSS = mkName "relationDictOwnsServiceProcessServiceName"
        relOSS = conT ''Relation                       `appT`
                 conT ''Owns                           `appT`
                 (conT ''ServiceProcess `appT` conT n) `appT`
                 conT ''ServiceName
    funOSS <- funD namOSS [clause [] (normalB $ conE 'Dict) []]
    sigOSS <- sigD namOSS (conT ''Dict `appT` relOSS)

    let namHSA = mkName "relationDictHasServiceProcessConfigItem"
        relHSA = conT ''Relation                       `appT`
                 conT ''HasConf                        `appT`
                 (conT ''ServiceProcess `appT` conT n) `appT`
                 conT n
    funHSA <- funD namHSA [clause [] (normalB $ conE 'Dict) []]
    sigHSA <- sigD namHSA (conT ''Dict `appT` relHSA)

    let namWSA = mkName "relationDictWantsServiceProcessConfigItem"
        relWSA = conT ''Relation                       `appT`
                 conT ''WantsConf                      `appT`
                 (conT ''ServiceProcess `appT` conT n) `appT`
                 conT n
    funWSA <- funD namWSA [clause [] (normalB $ conE 'Dict) []]
    sigWSA <- sigD namWSA (conT ''Dict `appT` relWSA)

    let namRA = mkName "resourceDictConfigItem"
        rrRA  = conT ''Resource `appT` conT n
    funRA <- funD namRA [clause [] (normalB $ conE 'Dict) []]
    sigRA <- sigD namRA (conT ''Dict `appT` rrRA)

    let namRSA = mkName "resourceDictService"
        rrRSA  = conT ''Resource `appT` (conT ''Service `appT` conT n)
    funRSA <- funD namRSA [clause [] (normalB $ conE 'Dict) []]
    sigRSA <- sigD namRSA (conT ''Dict `appT` rrRSA)

    let namRSSA = mkName "resourceDictServiceProcess"
        rrRSSA  = conT ''Resource `appT` (conT ''ServiceProcess `appT` conT n)
    funRSSA <- funD namRSSA [clause [] (normalB $ conE 'Dict) []]
    sigRSSA <- sigD namRSSA (conT ''Dict `appT` rrRSSA)

    let namSaDict = mkName "serializableDict"
    funSaDict <- funD namSaDict [clause [] (normalB $ conE 'SerializableDict) []]
    sigSaDict <- sigD namSaDict (conT ''SerializableDict `appT` conT n)

    let namConfDict = mkName ("configDict" ++ nameBase n)
    funConfDict <- funD namConfDict [clause [] (normalB $ conE 'Dict) []]
    sigConfDict <- sigD namConfDict (conT ''Dict `appT`
                                    (conT ''Configuration `appT` conT n))

    return [ sigSCS
           , funSCS
           , sigRNS
           , funRNS
           , sigISS
           , funISS
           , funOSS
           , sigOSS
           , sigHSA
           , funHSA
           , sigWSA
           , funWSA
           , funRA
           , sigRA
           , sigRSA
           , funRSA
           , sigRSSA
           , funRSSA
           , sigSaDict
           , funSaDict
           , funConfDict
           , sigConfDict
           ]

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

    -- Relation Runs Node (ServiceProcess a)
    let namRNS = mkName "relationDictHasNodeServiceProcess"
        relRNS = conT ''Relation `appT`
                 conT ''Runs `appT`
                 conT ''Node  `appT`
                 (conT ''ServiceProcess `appT` conT n)
    rRNS <- instanceD (cxt []) relRNS
            [ funD 'relationDict [clause [] (normalB $ mkStatic namRNS) []]]

    -- Relation InstanceOf (Service a) (ServiceProcess a)
    let namISS = mkName "relationDictInstanceOfServiceServiceProcess"
        relISS = conT ''Relation                `appT`
                 conT ''InstanceOf              `appT`
                 (conT ''Service `appT` conT n) `appT`
                 (conT ''ServiceProcess `appT` conT n)
    rISS <- instanceD (cxt []) relISS
            [ funD 'relationDict [clause [] (normalB $ mkStatic namISS) []]]

    -- Relation Owns (ServiceProcess a) ServiceName
    let namOSS = mkName "relationDictOwnsServiceProcessServiceName"
        relOSS = conT ''Relation                       `appT`
                 conT ''Owns                           `appT`
                 (conT ''ServiceProcess `appT` conT n) `appT`
                 conT ''ServiceName
    rOSS <- instanceD (cxt []) relOSS
            [ funD 'relationDict [clause [] (normalB $ mkStatic namOSS) []]]

    -- Relation HasConf (ServiceProcess a) a
    let namHSA = mkName "relationDictHasServiceProcessConfigItem"
        relHSA = conT ''Relation                       `appT`
                 conT ''HasConf                        `appT`
                 (conT ''ServiceProcess `appT` conT n) `appT`
                 conT n
    rHSA <- instanceD (cxt []) relHSA
            [ funD 'relationDict [clause [] (normalB $ mkStatic namHSA) []]]

    -- Relation WantsConf (ServiceProcess a) a
    let namWSA = mkName "relationDictWantsServiceProcessConfigItem"
        relWSA = conT ''Relation                       `appT`
                 conT ''WantsConf                      `appT`
                 (conT ''ServiceProcess `appT` conT n) `appT`
                 conT n
    rWSA <- instanceD (cxt []) relWSA
            [ funD 'relationDict [clause [] (normalB $ mkStatic namWSA) []]]

    -- Resource a
    let namRA = mkName "resourceDictConfigItem"
        rrRA  = conT ''Resource `appT` conT n
    rRA <- instanceD (cxt []) rrRA
           [ funD 'resourceDict [clause [] (normalB $ mkStatic namRA) []]]

    -- Resource (Service a)
    let namRSA = mkName "resourceDictService"
        rrRSA  = conT ''Resource `appT` (conT ''Service `appT` conT n)
    rRSA <- instanceD (cxt []) rrRSA
            [ funD 'resourceDict [clause [] (normalB $ mkStatic namRSA) []]]

    -- Resource (ServiceProcess a)
    let namRSSA = mkName "resourceDictServiceProcess"
        rrRSSA  = conT ''Resource `appT` (conT ''ServiceProcess `appT` conT n)
    rRSSA <- instanceD (cxt []) rrRSSA
             [ funD 'resourceDict [clause [] (normalB $ mkStatic namRSSA) []]]

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
                         , namRSSA
                         , namRSA
                         , namRA
                         , namWSA
                         , namHSA
                         , namOSS
                         , namISS
                         , namRNS
                         , namSCS
                         ] ++ othernames)

    let decs = [ rSCS
               , rRNS
               , rISS
               , rOSS
               , rHSA
               , rWSA
               , rRA
               , rRSA
               , rRSSA
               , saConf
               ]

    return (decs ++ stDecs)
