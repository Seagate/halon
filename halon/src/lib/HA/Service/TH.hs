{-# LANGUAGE DataKinds #-}
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
  , deriveProcessEncode
  ) where

import Language.Haskell.TH

import Control.Distributed.Process.Closure

import HA.ResourceGraph
import HA.Resources
import HA.Service

import Control.Distributed.Process.Internal.Types (remoteTable, processNode)
import Control.Distributed.Static (unstatic)
import Control.Monad.Reader ( asks )
import Data.Binary
import Data.Binary.Get (runGet)
import Data.Binary.Put (runPut)
import Data.Foldable (foldl')
import Data.Maybe (mapMaybe)
import Data.SafeCopy
--import Data.Serialize.Get (runGetLazy)
import Data.Serialize.Put (runPutLazy)
import HA.Encode

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
-- instance Relation Supports Cluster (Sevice N) where
--   type CardinalityFrom Supports Cluster (Service N) = AtMostOne
--   type CardinalityTo   Supports Cluster (Service N) = AtMostOne
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
    rSCS <- [d| instance Relation Supports Cluster (Service $(conT n)) where
                  type CardinalityFrom Supports Cluster (Service $(conT n))
                    = 'AtMostOne
                  type CardinalityTo   Supports Cluster (Service $(conT n))
                    = 'AtMostOne
                  relationDict = $(mkStatic namSCS)
              |]

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

    let decs = rSCS ++
               [ rRA
               , rRSA
               , saConf
               ]

    return (decs ++ stDecs)

-- | Derive 'ProcessEncode' instance for data type with existential
-- constructors and dictionaries.
deriveProcessEncode :: Name -- ^ Data type we need 'ProcessEncode' instance for.
                    -> Name -- ^ Data type used for binary representation
                    -> Name -- ^ Binary representation constructor
                            --
                            -- TODO: we can fairly easily retrieve it
                            -- and pass it around.
                    -> Q [Dec]
deriveProcessEncode typName repData repCon = do
  TyConI d <- reify typName
  return <$> mkInstance (getCons d)
  where
    getCons :: Dec -> [Constructor]
    getCons (DataD _ _ _ cons _) = map (conToConstructor []) cons
    getCons d = error $ "getCons: not a data type declaration: " ++ show d

    conToConstructor :: Cxt -> Con -> Constructor
    conToConstructor confs (NormalC n tys) = (n, map snd tys, confs)
    conToConstructor confs (ForallC _ cxt' con) = conToConstructor (confs ++ cxt') con
    conToConstructor _ c = error $ "conToConstructor: unexpected constructor: " ++ show c

    mkInstance :: [Constructor] -> DecQ
    mkInstance cons = instanceD (cxt []) (conT ''ProcessEncode `appT` conT typName) $
      [ tySynInstD ''BinRep $ tySynEqn [conT typName] (conT repData) ]
      ++ [mkEncodePs cons']
      ++ [mkDecodePs cons']
      where
        cons' = zip [0, 1..] cons

    mkEncodePs :: [(Integer, Constructor)] -> DecQ
    mkEncodePs [] = fail "mkEncodePs: no constructors"
    mkEncodePs [(_, c)] = funD 'encodeP [mkEncodeP Nothing c]
    mkEncodePs cs = funD 'encodeP $ map (\(ix, c) -> mkEncodeP (Just ix) c) cs

    mkEncodeP :: Maybe Integer -> Constructor -> ClauseQ
    mkEncodeP mIx (name, tys, cxt') = do
      vars <- mapM mkVar tys
      clause [conP name $ map (varP . snd) vars]
             (normalB $ mkEncodePBody mIx vars cxt') []

    -- TODO: put int/word not Integer
    mkEncodePBody :: Maybe Integer -> [(Type, Name)] -> Cxt -> ExpQ
    mkEncodePBody mIx vars cxt' = do
      putVars <- mapM (\v -> mkPutVarQ v cxt') vars
      appE (conE repCon) $ appE (varE 'runPut) $ doE $ concat $
        [ maybe [] (\i -> [ noBindS $ [| put ($(litE (integerL i)) :: Int) |] ]) mIx
        ] ++ putVars

    mkPutVarQ :: (Type, Name) -> Cxt -> Q [StmtQ]
    mkPutVarQ (t, n) cxt' = do
      configType <- conT ''Configuration
      isService <- isTypService t

      let getConfigVar (AppT mConf tVar) = case mConf == configType of
            True -> Just tVar
            False -> Nothing
          getConfigVar _ = Nothing

      let isConfig = case mapMaybe getConfigVar cxt' of
            [] -> False
            cVars -> any (== t) cVars

      return . map noBindS $ case isService of
        -- Write out dict then Service itself so we can use the dict
        -- trick when reading back
        True -> [ [| put (configDict $(varE n)) |]
                , [| put $(varE n) |] ]
        False -> case isConfig of
          True -> [ [| put (runPutLazy (safePut $(varE n))) |] ]
          False -> [ [| put $(varE n) |] ]

    mkVar :: Type -> Q (Type, Name)
    mkVar t = (,) <$> return t <*> newName "v"

    isTypService :: Type -> Q Bool
    isTypService t = case t of
      AppT t' _ -> do
        svcType <- conT ''Service
        return $ t' == svcType
      _ -> return False

    mkDecodePs :: [(Integer, Constructor)] -> DecQ
    mkDecodePs [] = fail "mkDecodePs: no constructors"
    mkDecodePs [(_, c)] = do
      bs <- newName "bs"
      funD 'decodeP [clause [conP repCon [varP bs]] (normalB $ decodeCon c) []]
    mkDecodePs cs = do
      bs <- newName "bs"
      funD 'decodeP [clause [conP repCon [varP bs]] (normalB $ mkDecodePBody bs cs) []]

    mkDecodePBody :: Name -> [(Integer, Constructor)] -> ExpQ
    mkDecodePBody bs cons = do
      i <- newName "i"
      doE [ bindS (varP i) [e| get :: Get Int |]
          , noBindS $ caseE (varE i) (map mkDecodePMatch cons ++ [decodeFailMatch i]) ]

    mkDecodePMatch :: (Integer, Constructor) -> MatchQ
    mkDecodePMatch (i, con) = match (litP (integerL i)) (normalB $ decodeCon con) []

    decodeCon :: Constructor -> ExpQ
    decodeCon (cname, cvars, cxt') = do
      rt <- newName "rt"
      getRT <- bindS (varP rt) [e| asks (remoteTable . processNode) |]
      vars <- mapM mkVar cvars
      results <- mapM (\v -> mkGetVarQ rt v cxt') vars
      let (names, stmts) = unzip results
      doE $ getRT : stmts ++ [mkReturn cname names]

    mkReturn :: Name -> [Name] -> StmtQ
    mkReturn cname names = noBindS $ do
      let applyReturn = foldl' (\l r -> l `appE` varE r) (conE cname) names
      [e| return $(parensE applyReturn) |]

    mkGetVarQ :: Name -> (Type, Name) -> Cxt -> Q (Name, StmtQ)
    mkGetVarQ rt (t, n) cxt' = do
      isService <- isTypService t
      configType <- conT ''Configuration
      let getConfigVar (AppT mConf tVar) = case mConf == configType of
            True -> Just tVar
            False -> Nothing
          getConfigVar _ = Nothing

      let isConfig = case mapMaybe getConfigVar cxt' of
            [] -> False
            cVars -> any (== t) cVars

      v <- newName "v"
      stmt <- bindS (varP v) $ case isService of
        True -> do
          d <- newName "d"
          s <- newName "s"
          err <- newName "err"
          doE
            [ bindS (varP d) [e| get |]
            , noBindS $ caseE [e| unstatic $(varE rt) $(varE d) |]
                [ match [p| Right (SomeConfigurationDict (Dict :: Dict (Configuration $(varT s)))) |]
                    (normalB [e| get :: Get (Service $(varT s)) |])
                    []
                , match [p| Left $(varP err) |] (normalB [e|
                    error ("decodeP " ++ nameBase t ++ ": dict decode failed with: " ++ $(varE err)) |])
                    []
                ]
            ]
        False -> case isConfig of
          True -> do
            [e| error "config variables decoding not supported yet" |]
{-
            bcfg <- newName "bcfg"
            cfg <- newName "cfg"
            [e| do $(varP bcfg) <- get
                   case runGetLazy safeGet bcfg of
                     Right $(varP cfg) -> return ($(varP cfg)

            doE [ bindS (varP bcfg) [e| bcfg
-}
          False -> [e| get |]
      return (v, return stmt)

    decodeFailMatch :: Name -> MatchQ
    decodeFailMatch i = do
      match wildP (normalB [e|
        error ("decodeP " ++ nameBase repData ++ ": no constructor with index "
                ++ show $(varE i))
       |]) []



-- | Constructor name, arguments, context
type Constructor = (Name, [Type], Cxt)
