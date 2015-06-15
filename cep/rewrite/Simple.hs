{-# LANGUAGE OverloadedStrings, GeneralizedNewtypeDeriving #-}

import Control.Exception hiding (assert)
import Control.Monad.Trans

import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Data.Binary (Binary)
import Data.Typeable
import Network.Transport.TCP

import Network.CEP

newtype Donut = Donut () deriving Binary

newtype Foo = Foo Int deriving Binary
newtype Baz = Baz Int deriving Binary

donut :: Donut
donut = Donut ()

newtype Res a = Res a deriving Binary

data GlobalState = GlobalState

test :: ProcessId -> Definitions GlobalState ()
test pid = do
    define "rule-1" $ do
      ph1 <- phaseHandle "state-1"
      ph2 <- phaseHandle "state-2"
      ph3 <- phaseHandle "state-3"
      ttt <- phaseHandle "test-seq"

      setPhase ph1 $ \(Donut _) -> do
        modify Local (+1)
        fork NoBuffer $ continue ph2

      setPhase ph2 $ \(msg :: String) ->
        case msg of
          "foo" -> modify Local (+1)
          "baz" -> do
            modify Local (+2)
            continue ph3

      setPhase ph3 $ \(i :: Int) -> do
        s <- get Local
        liftProcess $ usend pid (Res $ s + i)

      setPhaseSequenceIf ttt
        (\(Foo i) (Baz v) -> i `mod` v == 0) $ \(Foo i) (Baz v) -> do
          s <- get Local
          liftProcess $ usend pid $ Res (s+i+v)

      start ttt (1 :: Int)

player :: ProcessId -> Process ()
player pid = do
    usend pid donut
    usend pid ("baz" :: String)
    usend pid (3 :: Int)

playerSeq :: ProcessId -> Process ()
playerSeq pid = do
    usend pid (Foo 4)
    usend pid (Baz 2)

assert :: Bool -> Process ()
assert True = return ()
assert _    = error "assertion failure"

main :: IO ()
main = do
    t <- either throwIO return =<<
         createTransport "127.0.0.1" "4000" defaultTCPParameters
    n <- newLocalNode t initRemoteTable

    runProcess n $ do
      self <- getSelfPid
      pid  <- spawnLocal $ execute GlobalState (test self)

      playerSeq pid
      Res (i :: Int) <- expect
      assert $ i == 7
