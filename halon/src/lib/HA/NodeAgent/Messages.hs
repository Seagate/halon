-- |
-- Copyright : (C) 2013 Xyratex.
-- License   : All rights reserved.
--
-- Messages defined in a separate module to work around a Template Haskell stage
-- restriction.

{-# LANGUAGE TemplateHaskell #-}

module HA.NodeAgent.Messages where

import Control.Distributed.Process (NodeId)
import GHC.Generics (Generic)
import Data.Typeable (Typeable)
import Data.Binary (Binary)

-- | Messages for manipulating services.
data ServiceMessage
      -- | Update the pid of the event queue, for example, in the event of the
      -- RC restarting on a different node.
    = UpdateEQ [NodeId]
    deriving (Eq, Show, Generic, Typeable)

instance Binary ServiceMessage

data Result = Ok
            | CantUpdateEQ
            deriving (Eq, Show, Generic, Typeable)

instance Binary Result

data ExitReason = Shutdown
                deriving (Eq, Show, Generic, Typeable)

instance Binary ExitReason

