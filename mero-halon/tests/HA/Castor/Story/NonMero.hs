module HA.Castor.Story.NonMero
   ( tests
   ) where

import Network.Transport
import Network.CEP
import Control.Distributed.Process
import TestRunner
import           HA.NodeUp (nodeUp)
import RemoteTables ( remoteTable )
import HA.RecoveryCoordinator.Events.Mero

import Data.Proxy
import Test.Tasty
import Test.Framework


tests :: Transport -> TestTree
tests t = testSuccess "auto-discovery" $ testAutoDiscovery t

testAutoDiscovery :: Transport -> IO ()
testAutoDiscovery transport = do
    runTest 1 20 15000000 transport rt $ \_ -> do
      nid <- getSelfNode
      say $ "tests node: " ++ show nid
      withTrackingStation emptyRules $ \(TestArgs _ _mm rc) -> do
        subscribe rc (Proxy :: Proxy NewMeroClientProcessed)
        nodeUp ([nid], 1000000)
        _ <- receiveTimeout 1000000 []
        _ <- expect :: Process (Published NewMeroClientProcessed)
        return ()
  where
    rt = TestRunner.__remoteTableDecl $
         remoteTable
