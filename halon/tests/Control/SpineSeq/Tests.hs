-- |
-- Module:  Control.SpineSeq.Test
-- Copyright: (C) 2015 Seagate Technology Limited.

module Control.SpineSeq.Tests
  ( tests
  ) where

import Control.SpineSeq
import Control.Exception
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "SpineSeq"
  [ testCase "spineSeq doesn't evaluate values" $ do
      ex <- tryError $ evaluate $ length $ spineSeq ([error "1", error "2", error "3"] :: [Int])
      assertEqual "should be 3" (Right 3) ex
  , testCase "spineSeq doesn't evaluate spine" $ do
      ex <- tryError $ evaluate $ length $ spineSeq ((error "1":error "2": error "3") :: [Int])
      assertEqual "should be 3" (Left (ErrorCall "3")) ex
  ]

tryError :: IO a -> IO (Either ErrorCall a)
tryError = try
