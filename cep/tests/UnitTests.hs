module Main where

import Control.Exception

import Control.Distributed.Process.Node
import Network.Transport.TCP
import Test.Tasty
import Test.Tasty.Ingredients.Basic
import Test.Tasty.Ingredients.FileReporter
import Test.Tasty.HUnit

import Tests

ut :: IO TestTree
ut = do
    t <- either throwIO return =<<
         createTransport "127.0.0.1" "4000" defaultTCPParameters

    let launch action = do
          n <- newLocalNode t initRemoteTable
          runProcess n action

        grp = testGroup "CEP - Unit tests"
              [ testCase "Global state is updated" $
                launch globalUpdated
              , testCase "Local state is updated" $
                launch localUpdated
              , testCase "Switching is working" $
                launch switchIsWorking
              , testCase "Sequence is working" $
                launch sequenceIsWorking
              , testCase "Fork is working" $
                launch forkIsWorking
              , testCase "Init rule is working" $
                launch initRuleIsWorking
              , testCase "Peek and Shift are working" $
                launch peekShiftWorking
              ]

    return grp

main :: IO ()
main = do
    tree <- ut
    defaultMainWithIngredients [fileTestReporter [consoleTestReporter]] tree
