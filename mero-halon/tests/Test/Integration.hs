-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

{-# LANGUAGE CPP #-}
module Test.Integration (tests) where

import Test.Framework
import HA.Network.Address ( startNetwork, parseAddress )
import qualified HA.RecoveryCoordinator.Mero.Tests ( tests )

import Control.Applicative ((<$>))
import System.IO ( hSetBuffering, BufferMode(..), stdout, stderr )
import System.Environment (lookupEnv) 


-- | Temporary wrapper for components whose unit tests have not been broken up
-- into independent small tests.
monolith :: String -> IO () -> IO TestTree
monolith name = return . testSuccess name . withTmpDirectory

tests :: [String] -> IO TestTree
tests argv = do
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    addr0 <- case argv of
            a0:_ -> return a0
            _    ->
#ifdef USE_RPC
                 maybe (error "environement variable TEST_LISTEN is not set") id <$> lookupEnv "TEST_LISTEN"  
#else
                 maybe "localhost:0" id <$> lookupEnv "TEST_LISTEN"
#endif
    let addr = maybe (error "wrong address") id $ parseAddress addr0
    network <- startNetwork addr
    monolith "RC" $ HA.RecoveryCoordinator.Mero.Tests.tests addr0 network
