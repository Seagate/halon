{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE Rank2Types             #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE TemplateHaskell        #-}
-- |
-- Module    : HA.Service.Interface
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Interface serving as a communication shim between services and RC.
--
-- The idea is to unify the set of possible messages into a union and
-- have a single place where the communication implementation lives
-- for a service. This allows for further hiding of any extra details
-- such as version exchanges and updates from the rest of the service
-- code.
--
-- TODO: RFC 021
module HA.Service.Interface where

import           Control.Distributed.Process
import qualified Data.ByteString as BS
import           Data.Maybe (maybe)
import           GHC.Word (Word8)
import           HA.EventQueue.Producer (promulgateWait)
import           HA.SafeCopy (base, deriveSafeCopy)
import           HA.Service (Service(..))
import           Text.Printf (printf)
import           Network.CEP (liftProcess, MonadProcess)

-- | Alias for service names.
type ServiceName = String

-- | An on-wire format containing encoded data.
--
-- We rely on the 'StablePrint' of this type: you should not move it
-- to a different module or change the name nor type arguments of it.
data WireFormat = WireFormat
  { wfServiceName :: !ServiceName
  , wfVersion :: !Version
  , wfPayload :: !BS.ByteString
  } deriving (Show)

-- | Version wrapper.
newtype Version = Version Word8
  deriving (Show, Eq, Ord, Num, Enum)

data Interface toSvc fromSvc = Interface
  { ifVersion :: !Version
    -- ^ Version of the interface. This is used for checking if we're
    -- talking to a different version on the other side: it is up to
    -- the programmer to increment this in the interface
    -- implementation when making incompatible changes.
  , ifServiceName :: !ServiceName
  , ifEncodeToSvc :: Version -> toSvc -> Maybe WireFormat
    -- ^ Encode a message being sent to the service into a
    -- 'WireFormat'. Used when sending a message from RC to a service.
  , ifDecodeToSvc :: WireFormat -> Maybe toSvc
    -- ^ Decode a service message from 'WireFormat'. Used by a service
    -- when receiving a message from RC.
  , ifEncodeFromSvc :: Version -> fromSvc -> Maybe WireFormat
    -- ^ Encode a message being sent from the service to RC. Used by a
    -- service when sending.
  , ifDecodeFromSvc :: WireFormat -> Maybe fromSvc
    -- ^ Decode a message sent from the service to RC. Used by RC when
    -- receiving a message from a service.
  }

instance Show (Interface a b) where
  show i = printf "Interface { ifVersion = %s, ifServiceName = %s }"
                  (show $ ifVersion i) (ifServiceName i)

-- | Send the given message to the service registered on the given
-- node.
sendSvc :: (MonadProcess m, Show toSvc) => Interface toSvc a -> NodeId -> toSvc -> m ()
sendSvc Interface{..} nid toSvc = liftProcess $! case ifEncodeToSvc ifVersion toSvc of
  Nothing -> say $ printf "Unable to send %s to %s" (show toSvc) ifServiceName
  Just !wf -> nsendRemote nid (printf "service.%s" ifServiceName) wf

-- | Send the given message directly to the given process.
--
-- In general you should prefer 'sendSvc' and where possible,
-- restructuring the service such that the top-level listener
-- (@mainloop@ of the service) can forward messages to any slaves.
-- This is not always easy however, for example if we spawn some
-- ephemeral process per connection that will do the work.
sendSvcPid :: (MonadProcess m, Show toSvc) => Interface toSvc a -> ProcessId -> toSvc -> m ()
sendSvcPid Interface{..} pid toSvc = liftProcess $! case ifEncodeToSvc ifVersion toSvc of
  Nothing -> say $ printf "Unable to send %s to %s" (show toSvc) ifServiceName
  Just !wf -> usend pid wf

sendRC :: Show fromSvc => Interface a fromSvc -> fromSvc -> Process ()
sendRC Interface{..} fromSvc = case ifEncodeFromSvc ifVersion fromSvc of
  Nothing -> say $ printf "Unable to send %s to RC from %s with version %s."
                          (show fromSvc) ifServiceName (show ifVersion)
  Just !wf -> promulgateWait wf

receiveSvcIf :: Show toSvc => Interface toSvc a -> (toSvc -> Bool) -> (toSvc -> Process b) -> Match b
receiveSvcIf Interface{..} p act = matchIf (maybe False p . ifDecodeToSvc) $ \wf -> do
  case ifDecodeToSvc wf of
    Just toSvc -> act toSvc
    Nothing -> do
      let err_msg = printf "%s unable to decode %s" ifServiceName (show wf)
      say err_msg
      return $ error err_msg

receiveSvc :: Show toSvc => Interface toSvc a -> (toSvc -> Process b) -> Match b
receiveSvc iface act = receiveSvcIf iface (const True) act

class HasInterface svcConf toSvc fromSvc | svcConf -> toSvc, svcConf -> fromSvc where
  getInterface :: Service svcConf -> Interface toSvc fromSvc

-- Necessary for replication
deriveSafeCopy 0 'base ''Version
deriveSafeCopy 0 'base ''WireFormat
