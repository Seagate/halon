-- |
-- Module: HA.Storage.Tests
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.

module HA.Storage.Tests
  ( tests
  ) where

import qualified HA.Storage as Storage

import RemoteTables (remoteTable)

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Network.Transport (Transport)

import Test.Tasty
import Test.Tasty.HUnit

type SE a = Either Storage.StorageError a

withProcess :: LocalNode -> Process a -> IO a
withProcess node action = do
  box <- newEmptyMVar
  runProcess node $ action >>= liftIO . putMVar box
  takeMVar box

tests :: Transport -> IO TestTree
tests transport = do
  node <- newLocalNode transport remoteTable
  _    <- forkProcess node $ Storage.runStorage >> return ()
  return $ testGroup "HA.Storage"
             [ testCase "get . put == id" $ do
                  assertEqual "read value from storage" (Right (1::Int))
                    =<< withProcess node (do
                        Storage.put "key" (1::Int)
                        Storage.get "key")
            , testCase "get non existent value" $ do
                  assertEqual "value should not be found"
                              (Left Storage.KeyNotFound :: SE Int)
                    =<< withProcess node (Storage.get "key-not-exist")
            , testCase "get value of different type" $ do
                  assertEqual "value has different type"
                    (Left Storage.KeyTypeMithmatch :: SE Bool)
                    =<< withProcess node (do
                          Storage.put "key" (1::Int)
                          Storage.get "key")
            , testCase "put override value" $ do
                  assertEqual "put override value"
                              (Right 2 :: SE Int)
                    =<< withProcess node (do
                          Storage.put "key" (1::Int)
                          Storage.put "key" (2::Int)
                          Storage.get "key")
            , testCase "delete works" $ do
                  assertEqual "value should not be found"
                              (Left Storage.KeyNotFound :: SE Int)
                    =<< withProcess node (do
                          Storage.put "key" (1::Int)
                          Storage.delete "key"
                          Storage.get "key")
            ]


