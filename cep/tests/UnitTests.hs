module Main where

import Control.Exception

import Control.Distributed.Process.Node
import Network.Transport.TCP
import Test.Tasty
import Test.Tasty.Ingredients.Basic
import Test.Tasty.Ingredients.FileReporter
import qualified CEP.Settings.Tests (tests)

import Tests as Tests

ut :: IO TestTree
ut = do
    t <- either throwIO return =<<
         createTransport "127.0.0.1" "4000" defaultTCPParameters

    let launch action = do
          n <- newLocalNode t initRemoteTable
          runProcess n action
        grp = testGroup "CEP - Unit tests" $
              CEP.Settings.Tests.tests launch:Tests.tests launch

    return grp

main :: IO ()
main = do
    tree <- ut
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]] tree
