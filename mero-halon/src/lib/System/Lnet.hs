{-# LANGUAGE CPP                #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StrictData         #-}
{-# LANGUAGE TemplateHaskell    #-}
-- |
-- Module    : System.Lnet
-- Copyright : (C) 2015-2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Lnet querying.
module System.Lnet
  ( getLnetInfo
  , LnetInfo(..)
  , getLnetInfo__static
  , getLnetInfo__sdict
  , getLnetInfo__tdict
  , System.Lnet.__remoteTable
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure (remotable)
import           Control.Monad (unless)
import           Data.Either (isRight)
import qualified Data.Text as T
import           Data.Typeable (Typeable)
import           GHC.Generics
import           HA.EventQueue (promulgateWait)
import           HA.Resources (Node)
import           HA.SafeCopy
import           Mero.Lnet
import           System.Process
import           System.SystemD.API

-- | Hardware information about a 'Node'.
data LnetInfo = LnetInfo !Node !LNid
  deriving (Eq, Show, Typeable, Generic)

-- | Load information about system hardware. Reply is sent via 'promulgate'.
getLnetInfo :: Node -> Process ()
getLnetInfo nid = do
  say "Getting lnet info."
  liftIO (LnetInfo nid <$> getLNetID) >>= promulgateWait
  say "Got lnet info."

-- | Start @lnet@ service, query node IDs and return the first one reported.
--
-- Errors if service fails to start or no IDs are returned.
getLNetID :: IO LNid
getLNetID = do
  rc <- startService "lnet"
  unless (isRight rc) $ error "failed start lnet module"
  (nid:rest) <- lines <$> readProcess "lctl" ["list_nids"] ""
  unless (null rest) $ putStrLn "lctl reports many interfaces, but only first will be used"
  -- Hey, if we're going to blow up, we might as well blow up here and
  -- not in caller.
  case readLNid $ T.pack nid of
    Right lnid -> return lnid
    Left err -> error $ "Failed to parse LNid: " ++ show err

deriveSafeCopy 0 'base ''LnetInfo
remotable [ 'getLnetInfo ]
