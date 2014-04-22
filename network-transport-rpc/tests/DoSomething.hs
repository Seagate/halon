{-# LANGUAGE TemplateHaskell #-}
module DoSomething where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Distributed.Process.Internal.Types
import Control.Distributed.Process.Internal.StrictMVar
import qualified Network.Transport as NT
import Data.Map as Map
import Control.Monad.Reader
import System.IO

disconnectAllNodeConnections :: LocalNode -> IO ()
disconnectAllNodeConnections node =
  modifyMVar_ (localState node) $ \st -> do
     mapM_ closeIfNodeId . Map.toList $ _localConnections st
     return st { _localConnections = Map.empty }
 where
   closeIfNodeId ((NodeIdentifier _,_),(c,_)) = NT.close c
   closeIfNodeId _ = return ()

doSomething :: Bool -> Process ()
doSomething b = do
  liftIO $ hPutStrLn stderr (show b) >> hFlush stderr
  n <- fmap processNode ask
  liftIO $ disconnectAllNodeConnections n

remotable [ 'doSomething ]
