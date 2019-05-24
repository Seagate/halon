{-# LANGUAGE TupleSections #-}

module Main where

import Control.Exception

import Control.Distributed.Process.Node
import Network.Transport.TCP
import Test.Tasty
import Test.Tasty.Ingredients.Basic
import Test.Tasty.Ingredients.FileReporter
import qualified CEP.Settings.Tests (tests)
import qualified Regression (tests)

import qualified Tests as Tests

import System.Timeout


ut :: IO TestTree
ut = do
    t <- either throwIO return =<<
         createTransport (defaultTCPAddr "127.0.0.1" "4000") defaultTCPParameters

    let launch action =
          (>>= maybe (error "Timeout") return) $ timeout 10000000 $
            bracket (newLocalNode t initRemoteTable)
                    closeLocalNode $
                    flip runProcess action
        grp = testGroup "CEP - Unit tests" $
                  Regression.tests launch
                : CEP.Settings.Tests.tests launch
                : Tests.tests launch

    return grp

main :: IO ()
main = do
    tree <- ut
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]] tree
