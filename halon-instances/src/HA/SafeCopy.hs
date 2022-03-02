{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE PackageImports       #-}
{-# LANGUAGE QuasiQuotes          #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE MonoLocalBinds       #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
-- |
-- Module    : HA.SafeCopy
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Halon wrapper around "Data.SafeCopy", providing an augmented
-- 'deriveSafeCopy' that forces a proper 'B.Binary' instance on the
-- user. This module should be imported wherever 'SafeCopy' is needed.
-- @safecopy@ package should not be imported directly by users at all
-- as default generated 'B.Binary' instance will not do the right
-- thing.
--
-- Also provides some orphans instances for d-p types.
module HA.SafeCopy
  ( module Data.SafeCopy
  , deriveSafeCopy
  ) where


import "distributed-process" Control.Distributed.Process
import "distributed-process" Control.Distributed.Process.Serializable
import           Data.Binary (Binary, encode, decode)
import qualified Data.Binary as B
import           Data.Defaultable (Defaultable)
import           Data.List (foldl')
import qualified Data.SafeCopy as SC
import           Data.SafeCopy hiding (deriveSafeCopy)
import           Data.Serialize (Serialize(..))
import qualified Data.Serialize.Get as S
import qualified Data.Serialize.Put as S
import           Data.UUID (UUID)
import           Language.Haskell.TH
import           Network.Transport (EndPointAddress)
import "distributed-process-scheduler" System.Clock (TimeSpec)

-- | Like 'SC.deriveSafeCopy' but also inserts 'Binary' instance.
--
-- TODO: Extend to parametrised types.
deriveSafeCopy :: SC.Version a -> Name -> Name -> Q [Dec]
deriveSafeCopy v k d = do
  scInstance <- SC.deriveSafeCopy v k d
  (c, n) <- reify d >>= \case
    TyConI (DataD _ _ tyvs _ _ _) -> return $ mkInfo tyvs
    TyConI (NewtypeD _ _ tyvs _ _ _) -> return $ mkInfo tyvs
    i -> fail $ "HA.SafeCopy: Can't derive Binary for " ++ show i
  -- TODO: we should be able to do better on decode/encode front

  -- TODO: figure out how to use splice without this hack
  binInstance <- if length c > 0
    then [d|
      instance $(mkCtxT c) => B.Binary $(n) where
        put = B.put . S.runPutLazy . safePut
        get = B.get >>= either fail return . S.runGetLazy safeGet
      |]
    else [d|
      instance B.Binary $(n) where
        put = B.put . S.runPutLazy . safePut
        get = B.get >>= either fail return . S.runGetLazy safeGet
      |]
  return $ scInstance ++ binInstance

  where
    mkCtxT :: [TypeQ] -> TypeQ
    mkCtxT c = foldl' appT (tupleT (length c)) c

    mkInfo :: [TyVarBndr] -> ([TypeQ], TypeQ)
    mkInfo tyvs =
      let vars = map (varT . tyVarToN) tyvs
          n = foldl' appT (conT d) vars
          c = map (conT ''SafeCopy `appT`) vars
      in (c, n)


    tyVarToN :: TyVarBndr -> Name
    tyVarToN (PlainTV n) = n
    tyVarToN (KindedTV n _) = n

-- * Orphans

instance Serialize TimeSpec

-- | Note: this instance uses cereal instance, not binary one.
--
-- Why? ¯\_(ツ)_/¯
instance SafeCopy TimeSpec where
  kind = primitive

instance Binary a => SafeCopy (Defaultable a) where
  putCopy = contain . put . encode
  getCopy = contain $ fmap decode get

instance SafeCopy ProcessId where
  putCopy = contain . put . encode
  getCopy = contain $ fmap decode get
  kind = primitive

instance SafeCopy UUID where
  putCopy = contain . put . encode
  getCopy = contain $ fmap decode get
  kind = primitive

instance Serializable a => SafeCopy (SendPort a) where
  putCopy = contain . put . encode
  getCopy = contain $ decode <$> get
  kind = primitive

concat <$> mapM (SC.deriveSafeCopy 0 'primitive) [''EndPointAddress, ''NodeId]
