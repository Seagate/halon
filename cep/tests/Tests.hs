{-# LANGUAGE ScopedTypeVariables, GeneralizedNewtypeDeriving #-}

module Tests where

import Control.Distributed.Process
import Data.Binary (Binary)

import Network.CEP

newtype Donut = Donut () deriving Binary

newtype Foo = Foo Int deriving Binary
newtype Baz = Baz Int deriving Binary

donut :: Donut
donut = Donut ()

newtype Res a = Res a deriving Binary

data GlobalState = GlobalState

assert :: Bool -> Process ()
assert True = return ()
assert _    = error "assertion failure"

globalUpdated :: Process ()
globalUpdated = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute (1 :: Int) $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"

        setPhase ph1 $ \(Donut _) -> do
          modify Global (+1)
          continue ph2

        setPhase ph2 $ \(Donut _) -> do
          i <- get Global
          liftProcess $ usend self (Res i)

        start ph1 ()

    usend pid donut
    usend pid donut
    Res (i :: Int) <- expect
    assert $ i == 2

localUpdated :: Process ()
localUpdated = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"

        setPhase ph1 $ \(Donut _) -> do
          modify Local (+1)
          continue ph2

        setPhase ph2 $ \(Donut _) -> do
          i <- get Local
          liftProcess $ usend self (Res i)

        start ph1 (1 :: Int)

    usend pid donut
    usend pid donut
    Res (i :: Int) <- expect
    assert $ i == 2

switchIsWorking :: Process ()
switchIsWorking = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"
        ph4 <- phaseHandle "state-4"

        setPhase ph1 $ \(Donut _) -> do
          switch [ph2, ph3, ph4]

        setPhase ph2 $ \(Foo _) -> return ()

        setPhase ph3 $ \(Baz _) -> return ()

        setPhase ph4 $ \(Donut _) -> liftProcess $ usend self (Res ())

        start ph1 ()

    usend pid donut
    usend pid donut
    Res () <- expect
    return ()

sequenceIsWorking :: Process ()
sequenceIsWorking = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"

        setPhaseSequence ph1 $ \(Donut _) (Donut _) ->
          liftProcess $ usend self (Res ())

        start ph1 ()

    usend pid donut
    usend pid donut
    Res () <- expect
    return ()

forkIsWorking :: Process ()
forkIsWorking = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"

        setPhase ph1 $ \(Donut _) -> fork NoBuffer $
          liftProcess $ usend self (Res ())

        start ph1 ()

    usend pid donut
    Res () <- expect
    return ()
