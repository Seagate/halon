-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

{-# LANGUAGE CPP #-}

module Test.Run (runTests) where

import Test.Tasty (TestTree, defaultMainWithIngredients)
import Test.Tasty.Ingredients.Basic (consoleTestReporter)
import Test.Tasty.Ingredients.FileReporter (fileTestReporter)

import System.IO (hSetBuffering, BufferMode(..), stdout, stderr)
import Test.Transport
import System.Environment (getArgs)

import Prelude

runTests :: (AbstractTransport -> IO TestTree) -> IO ()
runTests tests = do
    -- TODO: Remove threadDelay after RPC transport closes cleanly
    hSetBuffering stdout LineBuffering
    hSetBuffering stderr LineBuffering
    argv <- getArgs
    let transports = case argv of
#if USE_RPC
           "--use-rpc-transport":as    -> [mkRPCTransport as]
#endif
           "--use-tcp-transport":_     -> [mkTCPTransport]
           "--use-inmemory-tranport":_ -> [mkInMemoryTransport]
           _                           -> [mkInMemoryTransport
                                          ,mkTCPTransport]
    mapM_ (\mkT -> do
              transport <- mkT
              defaultMainWithIngredients [fileTestReporter [consoleTestReporter]]
                =<< tests transport
              closeAbstractTransport transport)
          transports
