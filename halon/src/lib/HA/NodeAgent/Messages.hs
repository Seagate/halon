-- |
-- Copyright : (C) 2013 Xyratex.
-- License   : All rights reserved.
--
-- Messages defined in a separate module to work around a Template Haskell stage
-- restriction.

{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}

module HA.NodeAgent.Messages where

import HA.CallTimeout

#if ! MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Distributed.Process
  ( ProcessId
  , Process
  , NodeId
  , callLocal
  )
import GHC.Generics (Generic)
import Data.Typeable (Typeable)
import Data.Binary (Binary)


data ServiceMessage =
    -- | Update the nids of the EQs, for example, in the event of the
    -- RC restarting on a different node.
    UpdateEQNodes [NodeId]
  deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceMessage

data ExitReason = Shutdown     -- ^ Internal shutdown, for example bouncing service.
                | Reconfigure  -- ^ Service reconfiguration.
                | UserStop     -- ^ Shutdown requested by user.
                deriving (Eq, Show, Generic, Typeable)

instance Binary ExitReason

-- FIXME: Use a well-defined timeout.
updateEQNodes :: ProcessId -> [NodeId] -> Process Bool
updateEQNodes pid nodes =
    maybe False id <$> callLocal (callTimeout timeout pid (UpdateEQNodes nodes))
  where
    timeout = 3000000
