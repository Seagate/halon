module HA.Prelude.Internal
  ( -- * Distributed process
    CDP.Process
  , CDP.ProcessId
  , CDP.ProcessMonitorNotification(..) 
  , CDP.ProcessRegistrationException(..) 
  , CDP.SendPort
  , CDP.Message
  , CDP.NodeId
  , CDP.usend
  , CDP.expect
  , CDP.expectTimeout
  , CDP.receiveWait
  , CDP.receiveTimeout
  , CDP.getSelfPid
  , CDP.getSelfNode
  , CDP.monitor
  , CDP.link
  , CDP.liftIO
  , CDP.register
  , CDP.reregister
  , CDP.mkStaticClosure
  , CDP.mkClosure
  , CDP.remotable
  , CDP.functionTDict
  , CDP.functionSDict
  , CDP.whereis
  , CDP.match
  , CDP.matchIf
  , CDP.nsendRemote
  , CDP.say
  , CDP.newChan
  , CDP.sendChan
  , CDP.receiveChan
  , withMonitoring
  , schedulerIsEnabled
    -- * Standard library
  , (Data.Monoid.<>)
  , Data.Functor.void
  , Data.Function.fix
  , Data.Foldable.for_
  , (Control.Applicative.<|>)
  , Control.Monad.when
  , Control.Monad.unless
    -- * Exception handling
  , Control.Monad.Catch.try
  , Control.Monad.Catch.mask
  , Control.Monad.Catch.mask_
  , Control.Monad.Catch.bracket
  , Control.Monad.Catch.bracket_
  , Control.Monad.Catch.catch
  , Control.Monad.Catch.throwM
  , Control.Monad.Catch.handle
  , Control.Exception.SomeException
  , Control.Exception.IOException
    -- * Instances
  , Data.Hashable.Hashable
  , Data.Binary.Binary
  , Data.Typeable.Typeable
  , GHC.Generics.Generic
  ) where

import qualified Control.Applicative
import qualified Control.Distributed.Process as CDP
import qualified Control.Distributed.Process.Closure as CDP
import qualified Control.Monad
import qualified Control.Monad.Catch
import qualified Control.Exception
import qualified Data.Foldable
import qualified Data.Monoid
import qualified Data.Hashable
import qualified Data.Binary
import qualified Data.Typeable
import qualified Data.Functor
import qualified Data.Function
import qualified GHC.Generics
import Control.Distributed.Process.Monitor (withMonitoring)
import Control.Distributed.Process.Scheduler (schedulerIsEnabled)
