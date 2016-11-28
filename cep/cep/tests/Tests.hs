{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE TypeFamilies               #-}
module Tests where

import Control.Distributed.Process hiding (catch, try)
import Control.Monad (replicateM, replicateM_)
import Control.Monad.Catch (SomeException(..), catch, try, throwM)
import Control.Exception (Exception, fromException)
import Data.Binary (Binary)
import Data.Typeable
import Data.List (sort)
import Data.IORef
import Data.PersistMessage
import HA.SafeCopy
import qualified Data.UUID as UUID
import GHC.Generics

import System.Clock

import Test.Tasty
import Test.Tasty.HUnit (testCase)
import qualified Test.Tasty.HUnit as HU

import Network.CEP hiding (cepEngine, execute)
import qualified Network.CEP (cepEngine, execute)

data TestApp a

instance Application (TestApp a) where
  type GlobalState (TestApp a) = a
  type LogType (TestApp a) = ()

-- | Re-declare these here to make the `Application` type obvious
execute :: g -> Specification (TestApp g) () -> Process ()
execute = Network.CEP.execute

cepEngine :: g -> Specification (TestApp g) () -> Engine
cepEngine = Network.CEP.cepEngine

newtype Donut = Donut () deriving Binary

newtype Foo = Foo { unFoo :: Int } deriving (Show, Binary)
newtype Baz = Baz Int deriving (Show)

donut :: Donut
donut = Donut ()

newtype Res a = Res a deriving (Eq, Show, Binary)

data GlobalState = GlobalState

assert :: Bool -> Process ()
assert True = return ()
assert _    = error "assertion failure"

assertEqual :: (Show a, Eq a) => String -> a -> a -> Process ()
assertEqual s i r = liftIO $ HU.assertEqual s i r

assertBool :: String -> Bool -> Process ()
assertBool s b = liftIO $ HU.assertBool s b

assertFailure :: String -> Process ()
assertFailure s = liftIO $ HU.assertFailure s

tests :: (Process () -> IO ()) -> [TestTree]
tests launch =
  [ testsGlobal launch
  , testsSwitch launch
  , testsSequence launch
  , testsFork launch
  , testsInit launch
  , testsPeekShift launch
  , testsExecution launch
  , testSubscriptions launch
  , testsTimeout launch
  , testsFinalizer launch
  , testsException launch
  , testsDefaultHandler launch
  , testsPhaseIf launch
  , testsSMessage launch
  ]

testsGlobal :: (Process () -> IO ()) -> TestTree
testsGlobal launch = testGroup "State"
  [ testCase "Global state is updated"  $ launch globalUpdated
  , testCase "Global state is observable by all state machines" $ launch globalIsGlobal
  , testCase "Local state is updated" $ launch localUpdated
  ]

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
          continue ph1

        start ph1 ()

    usend pid donut
    usend pid donut
    assertEqual "Global state was updated" (Res (2::Int)) =<< expect

globalIsGlobal :: Process ()
globalIsGlobal = do
    self <- getSelfPid
    pid  <- spawnLocal $ do
      link self
      execute (1 :: Int) $ do
        define "rule" $ do
          ph1 <- phaseHandle "state-1"
          ph2 <- phaseHandle "state-2"
          ph3 <- phaseHandle "state-3"

          setPhase ph1 $ \(Foo{}) -> do
            fork CopyBuffer $ continue ph2
            fork CopyBuffer $ continue ph2
            stop

          setPhase ph2 $ \(Donut _) -> do
            modify Global (+1)
            continue ph3

          setPhase ph3 $ \(Donut _) -> do
            i <- get Global
            liftProcess $ usend self (Res i)
          start ph1 ()

    link pid
    usend pid (Foo 1)
    usend pid donut
    usend pid donut
    Res (i :: Int) <- expect
    Res (j :: Int) <- expect
    assertEqual "buffer should be updated globally" 3 i
    assertEqual "buffer should be updated globally" 3 j

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

testsSwitch :: (Process () -> IO ()) -> TestTree
testsSwitch launch = testGroup "Switch"
  [ testCase "Switching is working" $ launch switchIsWorking
  , testCase "Switch execute one rule" $ launch switchTerminate
  , testCase "Call continue in switch"  $ launch switchContinue
  , testCase "Call suspend in switch"   $ launch switchSuspend
  , testCase "Call stop in switch"  $ launch switchStop
  , testCase "Failed rules modify local state"
             $ launch $ switchFailedRulesDontChangeState "local" Local True
  , testCase "Failed rules not modify global state"
             $ launch $ switchFailedRulesDontChangeState "global" Global True
  , testCase "Direct switch works" $ launch switchDirect
  ]

switchDirect :: Process ()
switchDirect = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"
        setPhase ph1 $ \(Donut _) -> switch [ph2, ph3]
        setPhase ph2 $ \(Donut _) -> liftProcess $ usend self (Foo 0)
        directly ph3 $ liftProcess $ usend self (Foo 1)
        start ph1 ()

    usend pid donut
    Foo 1 <- expect
    return ()

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

-- | Check that switch is a rule terminator, check that only
-- first rule fire.
switchTerminate :: Process ()
switchTerminate = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"
        directly ph1 $ do
          liftProcess $ usend self (Res "ph1")
          switch [ph2, ph3]
        setPhase ph2 $ \(Foo _) ->
          liftProcess $ usend self (Foo 1)
        setPhase ph3 $ \(Foo _) ->
          liftProcess $ usend self (Baz 2)
        start ph1 ()
    assertEqual "direct phase fired"
                (Res "ph1") =<< expect
    usend pid (1::Int)
    usend pid (Foo 1)
    assertBool "ph2 commited" =<<
      receiveWait [ match (\Foo{} -> return True)
                  , matchAny (\_ -> say "here" >> return False)
                  ]
    usend pid (Foo 2) -- XXX: tick
    assertBool "ph3 did not fire" =<<
      receiveWait [ match (\(Res s) -> return $ s == "ph1")
                  , matchAny (\_ -> return False)
                  ]

-- | Check that continue exit a switch as expected
switchContinue :: Process ()
switchContinue = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"
        ph4 <- phaseHandle "state-4"
        setPhase ph1 $ \(Donut _) -> do
          switch [ph2,ph3]
        setPhase ph2 $ \(Foo _) ->
          continue ph4
        setPhase ph3 $ \(Baz _) ->
          liftProcess $ usend self (Baz 2)
        setPhase ph4 $ \(Baz _) ->
          liftProcess $ usend self (Baz 7)
        start ph1 ()
    usend pid (Donut ())
    usend pid (Foo 1)
    usend pid (Baz 0)
    Baz i <- expect
    assert (i==7)

switchSuspend :: Process ()
switchSuspend = do
    ioref <- liftIO $ newIORef True
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"
        directly ph1 $ switch [ph2,ph3]
        setPhase ph2 $ \(Foo i) -> do
          liftProcess $ usend self "ph2"
          if i < 20
          then do liftProcess $ usend self "ph2s"
                  suspend
          else do liftProcess $ usend self "ph2f"

        setPhase ph3 $ \(Foo i) -> do
          liftProcess $ usend self "ph3"
          isFirst <- liftIO $ readIORef ioref
          if isFirst
          then do liftIO $ writeIORef ioref False
                  liftProcess $ usend self "ph3s"
                  suspend
          else do liftProcess $ usend self $ "ph3f" ++ show i
                  continue ph1
        start ph1 ()
    usend pid (Foo 4)
    assertEqual "all phases should suspend"
                ["ph2","ph2s","ph3","ph3s"]
                =<< replicateM 4 expect

    usend pid (Foo 21)
    assertEqual "not last rule will fire for the first message"
                ["ph2","ph2s","ph3","ph3f4"]
                =<< replicateM 4 expect
    usend pid (Foo 0)
    assertEqual "not last rule will fire for the first message"
                ["ph2","ph2f"]
                =<< replicateM 2 expect
    return ()

switchStop :: Process ()
switchStop = do
    ioref <- liftIO $ newIORef True
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"
        ph4 <- phaseHandle "state-4"
        directly ph1 $ switch [ph2,ph3, ph4]
        setPhase ph2 $ \(Foo i) -> do
          liftProcess $ usend self "ph2"
          if i == 0
          then stop
          else liftProcess $ usend self "ph2f"
        setPhase ph3 $ \(Foo i) -> do
          liftProcess $ usend self "ph3"
          if i == 0
          then stop
          else liftProcess $ usend self "ph3f"
        setPhase ph4 $ \(Foo i) -> do
          liftProcess $ usend self "ph4"
          v <- liftIO $ readIORef ioref
          if v
          then do liftProcess $ usend self "ph4s"
                  liftIO $ writeIORef ioref False
                  suspend
          else liftProcess $ usend self $ "ph4f" ++ show i
        start ph1 ()
    usend pid (Foo 0)
    assertEqual "stopped and suspended"
                ["ph2","ph3","ph4","ph4s"]
                =<< replicateM 4 expect
    usend pid (Foo 1)
    assertEqual "only last rule was tested and  fire"
                ["ph4", "ph4f0"]
                =<< replicateM 2 expect
    return ()

switchFailedRulesDontChangeState :: String -> Scope Int Int Int -> Bool -> Process ()
switchFailedRulesDontChangeState s l b = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute (9) $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"
        ph4 <- phaseHandle "state-4"
        directly ph1 $ switch [ph2,ph3,ph4]
        setPhase ph2 $ \(Donut _) -> do
          modify l succ
          suspend
        setPhase ph3 $ \(Donut _) -> do
          modify l succ
          stop
        setPhase ph4 $ \(Donut _) -> do
          i <- get l
          liftProcess $ usend self (Baz i)
        start ph1 (9::Int)
    usend pid donut
    Baz i <- expect
    assertEqual ("failed rules should not modify " ++ s ++ " state") b (i==9)

testsSequence :: (Process () -> IO ()) -> TestTree
testsSequence launch = testGroup "Sequence"
    [ testCase "Sequence is working"         $ launch sequenceIsWorking
    , testCase "Sequence under input in different order"  $ launch sequenceAdvanced
    , testCase "Sequence do not lose messages" $ launch sequenceDoNotLoseMessages
    ]

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

sequenceAdvanced :: Process ()
sequenceAdvanced = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
            define "rule" $ do
              ph1 <- phaseHandle "state-1"
              ph2 <- phaseHandle "state-2"
              setPhaseSequence ph1 $ \(Foo i) (Baz j) -> do
                liftProcess $ usend self (Foo $ i+j)
                if i+j>16
                then continue ph2
                else continue ph1
              setPhase ph2 $ \(Baz j) -> liftProcess $ usend self (Foo j)
              start ph1 ()
    usend pid (Foo 1)
    usend pid (Baz 2)
    assertEqual "event should be handled" 3 . unFoo =<< expect
    usend pid (Baz 3)
    usend pid (Foo 4)
    usend pid (Baz 5)
    assertEqual "events are handled in order" 9 . unFoo =<< expect
    usend pid (Foo 6)
    usend pid (Foo 7)
    usend pid (Baz 8)
    assertEqual "events are handled in order" 14 . unFoo =<< expect
    usend pid (Foo 9)
    usend pid (Donut ())
    usend pid (Baz 10)
    assertEqual "events are handled in order" 17 . unFoo =<< expect
    usend pid (Donut ())
    assertEqual "we have not loose any message" 3 . unFoo =<< expect

sequenceDoNotLoseMessages :: Process ()
sequenceDoNotLoseMessages = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
              define "rule" $ do
                ph1 <- phaseHandle "state-1"
                setPhaseSequence ph1 $ \(Foo i) (Baz j) -> do
                  liftProcess $ usend self (Foo $ i+j)
                start ph1 ()
    usend pid (Foo 1)
    usend pid (Foo 2)
    usend pid (Baz 3)
    assertEqual "events are handled in order" 4 . unFoo =<< expect
    usend pid (Foo 4)
    usend pid (Baz 5)
    assertEqual "events are handled in order" 7 . unFoo =<< expect
    usend pid (Baz 6)
    assertEqual "events are handled in order" 10 . unFoo =<< expect

testsFork :: (Process () -> IO ()) -> TestTree
testsFork launch = testGroup "Fork"
  [ testCase "Peek shift is working" $ launch forkIsWorking
  , testCase "Fork copies local state" $ launch forkCopyLocalState
  , testCase "Fork copies curent buffer" $ launch forkCopyLocalBuffer
  , testCase "Fork do not copy other rules" $ launch forkDontCopyOtherRules
  , testCase "Service usecase-1" $ launch forkServiceUsecase
  , testCase "Fork increments number of SMs" $ launch forkIncrSMs
  , testCase "Fork consume message" $ launch forkConsumeMsgs
  , testCase "Fork drop is working" $ launch forkDropIsWorking
  ]

forkConsumeMsgs :: Process ()
forkConsumeMsgs = do
  self <- getSelfPid
  pid  <- spawnLocal $ execute () $ do
    define "rule" $ do
      ph0 <- phaseHandle "state-0"
      ph1 <- phaseHandle "state-1"
      ph2 <- phaseHandle "state-2"
      end <- phaseHandle "end"
      setPhase ph0 $ \(Donut _) -> do
        fork NoBuffer $ do
          continue end
        switch [ph1, ph2]
      setPhase ph1 $ \(Donut _) -> do
        liftProcess $ usend self (Foo 1)
        continue end
      directly ph2 $ do
        liftProcess $ usend self (Foo 2)
        continue end
      directly end $ stop
      start ph0 ()
  usend pid donut
  assertEqual "foo" 2 . unFoo =<< expect

forkServiceUsecase :: Process ()
forkServiceUsecase = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph0 <- phaseHandle "state-1"
        ph1 <- phaseHandle "state-2"
        ph2 <- phaseHandle "state-3"
        setPhase ph0 $ \(Baz{}) -> do
          continue ph1

        setPhase ph1 $ \(Donut _) -> do
          fork CopyBuffer $ do
            continue ph2
          continue ph1

        setPhase ph2 $ \(Foo i) -> do
          liftProcess $ usend self (Foo i)
          continue ph2

        start ph0 ()

    replicateM_ 3 $ usend pid donut
    usend pid (Baz 4)
    usend pid (Foo 0)
    assertEqual "foo" [0,0,0] . map unFoo
      =<< replicateM 3 expect


forkDropIsWorking :: Process ()
forkDropIsWorking = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph0 <- phaseHandle "state-1"
        ph1 <- phaseHandle "state-2"
        ph2 <- phaseHandle "state-3"
        setPhase ph0 $ \(Donut _) -> do
          continue ph1

        setPhase ph1 $ \(Baz _) -> do
          fork CopyNewerBuffer $ do
            continue ph2
          continue ph1

        setPhase ph2 $ \(Foo i) -> do
          liftProcess $ usend self (Foo i)
          continue ph2

        start ph0 ()

    mapM_ (usend pid . Foo) [1,2,3]
    usend pid donut
    usend pid (Baz 4)
    mapM_ (usend pid . Foo) [4,5,6]

    assertEqual "foo" [4,5,6] . map unFoo
      =<< replicateM 3 expect

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
    usend pid donut
    Res () <- expect
    return ()

forkCopyLocalState :: Process ()
forkCopyLocalState = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        setPhase ph1 $ \(Donut _) -> do
          modify Local succ
          fork NoBuffer $ do
            modify Local succ
            liftProcess $ usend self (Res ())
            continue ph2
          continue ph2
        setPhase ph2 $ \(Donut _) -> do
          i <- get Local
          liftProcess $ usend self (Foo i)
        start ph1 (1::Int)
    usend pid donut
    assertEqual "Process forked" (Res ()) =<< expect
    usend pid donut
    assertEqual "Local state was copied" [2,3] =<<
          sort . map unFoo <$> replicateM 2 expect

forkCopyLocalBuffer :: Process ()
forkCopyLocalBuffer = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        setPhaseSequence ph1 $ \(Foo i) (Donut _) -> do
          fork CopyBuffer $ do
            liftProcess $ usend self (Res ())
            continue ph1
          liftProcess $ usend self (Foo i)
          continue ph1
        start ph1 ()
    usend pid (Foo 1)
    usend pid (Foo 2)
    usend pid donut
    assertEqual "Process forked" (Res ()) =<< expect
    assertEqual "Rule used first message" 1 . unFoo =<< expect
    usend pid donut
    assertEqual "Local state was copied" [2,2] =<<
          map unFoo <$> replicateM 2 expect

forkDontCopyOtherRules :: Process ()
forkDontCopyOtherRules = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule-1" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "barrier"
        setPhase ph1 $ \(Donut _) -> do
          fork NoBuffer $
            liftProcess $ usend self (Res ())
          continue ph2
        setPhase ph2 $ \(Donut _) ->
            liftProcess $ usend self (Res ())
        start ph1 ()
      define "rule-2" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        setPhase ph1 $ \(Foo i) -> do
          liftProcess $ usend self (Foo i)
          continue ph2
        setPhase ph2 $ \(Foo i) -> do
          liftProcess $ usend self (Foo (i*2))
        start ph1 ()
    usend pid (Foo 1)
    assertEqual "Second rule changed" 1 . unFoo =<< expect
    usend pid donut
    assertEqual "Process forked" (Res ()) =<< expect
    usend pid (Foo 2)
    assertEqual "Second rule state2 fired twice" 4
      . unFoo =<< expect
    usend pid donut
    assertEqual "Rules should not be copied" True
      =<< receiveWait
            [ match $ \(Res()) -> return True
            , match $ \Foo{}   -> return False
            ]

testsInit :: (Process () -> IO ()) -> TestTree
testsInit launch = testGroup "Init"
  [ testCase "Init rule is working" $ launch initRuleIsWorking
  , testCase "Init rule forwards processed messages" $ launch initRuleForward
  ]

initRuleIsWorking :: Process ()
initRuleIsWorking = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute (1 :: Int) $ do

      initRule $ do
        ph1 <- phaseHandle "init-1"
        ph2 <- phaseHandle "init-2"

        directly ph1 $ do
          modify Global (+1)
          continue ph2

        setPhase ph2 $ \(Donut _) ->
          modify Global (+2)

        start ph1 ()

      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"

        setPhase ph1 $ \(Foo {}) -> do
          modify Global (+3)
          continue ph2

        setPhase ph2 $ \(Donut _) -> do
          i <- get Global
          liftProcess $ usend self (Res i)

        start ph1 ()

    usend pid (Foo 0)
    usend pid donut
    usend pid donut
    Res (i :: Int) <- expect
    assert $ i == 7

initRuleForward :: Process ()
initRuleForward = do
    self <- getSelfPid
    pid <- spawnLocal $ execute (1 :: Int) $ do
      initRule $ do
        home <- phaseHandle "home"

        setPhase home $ \(Donut _) -> return ()

        start home ()

      defineSimple "forwarded" $ \(Donut _) -> liftProcess $ usend self ()

    usend pid donut
    expect

testsPeekShift :: (Process () -> IO ()) -> TestTree
testsPeekShift launch = testGroup "Buffer"
  [ testCase "Peek shift is working" $ launch peekShiftWorking
  , testCase "Should not lose any msg" $ launch shouldNotLooseMgs
  ]

peekShiftWorking :: Process ()
peekShiftWorking = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"

        tok <- wants (Proxy :: Proxy Donut)

        directly ph1 $ do
          (_, Donut _) <- peek tok initIndex
          continue ph2

        directly ph2 $ do
          (_, Donut _) <- shift tok initIndex
          liftProcess $ usend self (Res ())

        start ph1 ()

    usend pid donut
    Res () <- expect
    return ()

shouldNotLooseMgs :: Process ()
shouldNotLooseMgs = do
    let defs = define "do-not-loose-it" $ do
          ph0 <- phaseHandle "ph0"
          ph1 <- phaseHandle "ph1"
          ph2 <- phaseHandle "ph2"
          ph3 <- phaseHandle "ph3"

          directly ph0 $ switch [ph1, ph2]

          setPhase ph1 $ \(Foo _) ->
            continue ph3

          setPhase ph2 $ \(Baz _) -> return ()

          setPhase ph3 $ \(Donut _) -> return ()

          start ph0 ()

        msgs = [ Some $ incoming $ Foo 1
               , Some $ incoming $ Baz 1
               , Some $ incoming  donut
               ]

    (infos, _) <- feedEngine msgs $ cepEngine () defs
    let last_run = fst . last $ zip infos (tail infos)
        RunInfo _ (RulesBeenTriggered [rinfo]) = last_run
        RuleInfo _ [(st, _)]  = rinfo
    case st of
      SMRunning  -> return ()
      SMFinished -> return ()
      _          -> assertFailure "message was lost"
    return ()

forkIncrSMs :: Process ()
forkIncrSMs = do
  let defs = define "fork-it" $ do
        ph <- phaseHandle "phase-1"

        directly ph $ fork CopyBuffer $ return ()

        start ph ()
      start_engine = cepEngine () defs

  (RunInfo _ res, _) <- stepForward tick start_engine
  let RulesBeenTriggered res' = res
  assertEqual "only one rule fired" 1 (length res')
  let (RuleInfo _ rep:_)           = res'
  assertEqual "new VM were spawned" 2 (length rep)

testsExecution :: (Process () -> IO ()) -> TestTree
testsExecution launch = testGroup "Execution properties"
  [ -- localOption (mkTimeout 500000) $ testCase "Loop do not prevent cep from working" $ launch loopWorks
    HU.testCaseSteps "Parallel rule execution"
                                   $ launch . testSequenceRules
  , testCase "State machine runs to the end with helper"
                                   $ launch $ testConsumption 2
  , testCase "State machine runs to the end with another rule"
                                   $ launch $ testConsumption 1
  , testCase "State machine runs to the end" $ launch $ testConsumption 0
  , testCase "Direct rule is always executed" $ launch $ testConsumptionDirect
  , testCase "Stop works" $ launch $ testStopWorks
  ]

testStopWorks :: Process ()
testStopWorks = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule-1" $ do
        ph1 <- phaseHandle "state-1"
        setPhase ph1 $ \(Donut ()) ->
          liftProcess $ usend self "."
        start ph1 ()
      define "rule-2" $ do
        ph1 <- phaseHandle "state-1"
        setPhase ph1 $ \(Donut ()) -> do
          liftProcess $ usend self "."
          stop
        start ph1 ()
    usend pid donut
    assertEqual "both rules processed" [".","."]
      =<< replicateM 2 expect
    usend pid donut
    assertEqual "one rule both rules processed" "."
      =<< expect
    assertEqual "one rule both rules processed" (Nothing :: Maybe String)
      =<< expectTimeout 0
    return ()



loopWorks :: Process ()
loopWorks = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        loop1 <- phaseHandle "state-1"
        loop2 <- phaseHandle "state-2"
        reply <- phaseHandle "state-3"
        initial <- phaseHandle "state-4"
        directly initial $ do
          fork NoBuffer $ continue loop1
          continue reply
        setPhase reply $ \(Donut ()) -> liftProcess $ usend self (Res ())
        directly loop1 $ continue loop2
        directly loop2 $ continue loop1
        start initial ()
    usend pid donut
    Res () <- expect
    return ()

testSequenceRules :: (String -> IO ()) -> Process ()
testSequenceRules _step = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        setPhase ph1 $ \(Donut ()) -> do
          liftProcess $ usend self "ph1"
          continue ph2
        setPhase ph2 $ \(Foo i) -> do
          liftProcess $ usend self $ "ph2-" ++ show i
        start ph1 ()
    usend pid donut
    assertEqual "phase1" "ph1" =<< expect
    usend pid (Foo 1)
    assertEqual "phase2" "ph2-1" =<< expect
    usend pid donut
    assertEqual "phase1" "ph1" =<< expect
    usend pid (Foo 2)
    assertEqual "phase2" "ph2-2" =<< expect
    usend pid donut
    assertEqual "rule starts" "ph1" =<< expect
    usend pid donut
    usend pid (Foo 2)
    assertEqual "rule finishes" "ph2-2" =<< expect
    usend pid (Foo 3)
    assertEqual "second () was processed" "ph1" =<< expect

testConsumption :: Int -> Process ()
testConsumption hlpr = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        helper <- phaseHandle "state-3"
        setPhase ph1 $ \(Donut ()) -> do
          liftProcess $ usend self "ph1"
          continue ph2
        setPhase ph2 $ \(Foo i) -> do
          liftProcess $ usend self $ "ph2-" ++ show i
        setPhase helper $ \() -> return ()
        start ph1 ()
      define "another" $ do
        ph1 <- phaseHandle "state-0"
        setPhase ph1 $ \(Baz _) -> return ()
        start ph1 ()

    usend pid donut
    assertEqual "rule starts" "ph1" =<< expect
    usend pid donut
    usend pid (Foo 2)
    assertEqual "rule finishes" "ph2-2" =<< expect
    case hlpr of
      1 -> usend pid (Baz 3)
      2 -> usend pid ()
      _ -> return ()
    assertEqual "second () was processed" "ph1" =<< expect

testConsumptionDirect :: Process ()
testConsumptionDirect = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute () $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        directly ph1 $ do
          liftProcess $ usend self "ph1"
          continue ph2
        setPhase ph2 $ \Donut{} -> return ()
        start ph1 ()
    assertEqual "rule starts" "ph1" =<< expect
    usend pid donut
    assertEqual "rule finishes" "ph1" =<< expect

testSubscriptions :: (Process () -> IO ()) -> TestTree
testSubscriptions launch = testGroup "Subscription properties"
    [ testCase "CEP should forward events" $ launch testSimpleSub
    , testCase "Unsubsciption works" $ launch testUnsubscribe
    ]

testSimpleSub :: Process ()
testSimpleSub = do
    self <- getSelfPid
    let defs = define "fork-it" $ do
          ph <- phaseHandle "phase-1"

          setPhase ph $ \(Foo _) ->
            publish $ Baz 1

          start ph ()
        start_engine = cepEngine () defs

    let msgs = [ Some $ subscribeRequest self (Proxy :: Proxy Foo)
               , Some $ subscribeRequest self (Proxy :: Proxy Baz)
               , Some $ incoming $ Foo 1
               ]
    _ <- spawnLocal $ do
      _ <- feedEngine msgs start_engine
      return ()

    _ <- expect :: Process (Published Foo)
    _ <- expect :: Process (Published Baz)
    return ()

testUnsubscribe :: Process ()
testUnsubscribe = do
  self <- getSelfPid
  let defs = define "fork" $ do
       ph <- phaseHandle "phase-1"
       setPhase ph $ \Donut{} -> do
         publish ()
         liftProcess $ usend self ()
       start ph ()
  pid <- spawnLocal $ execute () defs
  subscribe pid (Proxy :: Proxy ())
  usend pid donut
  _ <- expect :: Process (Published ())
  assertEqual "message sent" () =<< expect
  unsubscribe pid (Proxy :: Proxy ())
  usend pid donut
  receiveWait [ match $ \(Published () _) -> assertFailure "unexpected message"
              , match $ \() -> return ()
              ]


testsTimeout :: (Process () -> IO ()) -> TestTree
testsTimeout launch = testGroup "Timeout properties"
  [ testCase "Simple Timeout should work" $ launch testSimpleTimeout
  , testCase "All timeout should work" $ launch testAllTimeout
  , testCase "Continue timeout should work" $ launch testContinueTimeout
  -- , testCase "Init rule timeout should work" $ launch testInitTimeout
  , testCase "Start timeout should work" $ launch testStartTimeout
  , testCase "SetPhase timeout should work" $ launch testSetPhaseTimeout
  , testCase "All timeout reverse should work" $ launch testAllReverseTimeout
  , testCase "Timout works for fork" $ launch testForkTimeout
  ]

testForkTimeout :: Process ()
testForkTimeout = do
    self <- getSelfPid
    let specs = do
          define "timeout" $ do
            ph2 <- phaseHandle "ph2"
            ph0 <- phaseHandle "ph0"
            ph1 <- phaseHandle "ph1"
            setPhase ph2 $ \Donut{} -> continue ph0
            directly ph0 $ fork NoBuffer $ continue (timeout 1 ph1)
            directly ph1 $ liftProcess (usend self ()) >> stop
            start ph2 ()
    pid <- spawnLocal $ execute () specs
    usend pid donut
    expect

testSimpleTimeout :: Process ()
testSimpleTimeout = do
    self <- getSelfPid
    let specs = do
          define "timeout" $ do
            ph0 <- phaseHandle "ph0"
            ph1 <- phaseHandle "ph1"
            ph2 <- phaseHandle "ph2"

            directly ph0 $ switch [ph1, timeout 1 ph2]

            setPhase ph1 $ \(Donut _) -> return ()

            directly ph2 $ liftProcess $ usend self ()

            start ph0 ()

    _ <- spawnLocal $ execute () specs
    expect

testAllTimeout :: Process ()
testAllTimeout = do
    self <- getSelfPid

    let specs = define "all-timeout" $ do
          ph0 <- phaseHandle "ph0"
          ph1 <- phaseHandle "ph1"
          ph2 <- phaseHandle "ph2"

          directly ph0 $ switch [timeout 2 ph1, timeout 3 ph2]

          setPhase ph1 $ \(Donut _) -> liftProcess $ usend self (1 :: Int)

          setPhase ph2 $ \(Foo _) -> liftProcess $ usend self (2 :: Int)

          start ph0 ()

    pid <- spawnLocal $ execute () specs
    usend pid (Foo 1)
    usend pid donut

    i <- expect
    assertEqual "Ph1 should fire first" (1 :: Int) i

testContinueTimeout :: Process ()
testContinueTimeout = do
    self <- getSelfPid

    let specs = define "continue-timeout" $ do
          ph0 <- phaseHandle "ph0"
          ph1 <- phaseHandle "ph1"

          directly ph0 $ continue $ timeout 2 ph1

          setPhase ph1 $ \(Donut _) -> liftProcess $ usend self ()

          start ph0 ()

    pid <- spawnLocal $ execute () specs
    begin <- liftIO $ getTime Monotonic
    usend pid donut
    () <- expect
    end <- liftIO $ getTime Monotonic
    let diff = diffTimeSpec end begin
        test = diff >= TimeSpec 2 0
    assertEqual ("Should take at least 2 seconds ("++ show diff++")") True test

{-
testInitTimeout :: Process ()
testInitTimeout = do
    self <- getSelfPid

    let specs = initRule $ do
          ph0 <- phaseHandle "ph0"
          ph1 <- phaseHandle "ph1"

          directly ph0 $ continue $ timeout 2 ph1

          setPhase ph1 $ \(Donut _) -> liftProcess $ usend self ()

          start ph0 ()

    pid <- spawnLocal $ execute () specs
    usend pid donut
    expect
-}

testStartTimeout :: Process ()
testStartTimeout = do
    self <- getSelfPid

    let specs = define "start-timeout" $ do
          ph0 <- phaseHandle "ph0"

          setPhase ph0 $ \(Donut _) -> liftProcess $ usend self ()

          start (timeout 2 ph0) ()

    pid <- spawnLocal $ execute () specs
    usend pid donut
    expect

testSetPhaseTimeout :: Process ()
testSetPhaseTimeout = do
    self <- getSelfPid

    let specs = define "set-phase-timeout" $ do
          ph0 <- phaseHandle "ph0"

          setPhase (timeout 2 ph0) $ \(Donut _) -> liftProcess $ usend self ()

          start ph0 ()

    pid <- spawnLocal $ execute () specs
    usend pid donut
    expect

testAllReverseTimeout :: Process ()
testAllReverseTimeout = do
    self <- getSelfPid

    let specs = define "all-timeout" $ do
          ph0 <- phaseHandle "ph0"
          ph1 <- phaseHandle "ph1"
          ph2 <- phaseHandle "ph2"

          directly ph0 $ switch [timeout 3 ph1, timeout 2 ph2]

          setPhase ph1 $ \(Donut _) -> liftProcess $ usend self (1 :: Int)

          setPhase ph2 $ \(Foo _) -> liftProcess $ usend self (2 :: Int)

          start ph0 ()

    pid <- spawnLocal $ execute () specs
    usend pid donut
    usend pid (Foo 1)

    i <- expect
    assertEqual "Ph2 should fire first" (2 :: Int) i

testsFinalizer :: (Process () -> IO ()) -> TestTree
testsFinalizer launch = testGroup "Finalizer"
  [ testCase "Finalizer is triggered each phase transition"  $ launch testFinalizerDirectly
  ]

testFinalizerDirectly :: Process ()
testFinalizerDirectly = do
  self <- getSelfPid
  let specs = define "finalizer-directly" $ do
        ph0 <- phaseHandle "ph0"
        ph1 <- phaseHandle "ph1"
        setPhase ph0 $ \(Donut _) -> liftProcess (usend self (Foo 1)) >> continue ph1
        directly ph1 $ liftProcess $ usend self (Foo 2)
        start ph0 ()
  pid <- spawnLocal $ execute () $ do
          specs
          setRuleFinalizer $ \s -> usend self (Foo 0) >> return s

  usend pid donut
  assertEqual "event should be handled" [0,1,0]
    . map unFoo =<< replicateM 3 expect

testsException :: (Process () -> IO ()) -> TestTree
testsException launch = testGroup "Exception"
  [ testCase "Exception can be handled" $ launch exceptionWorks
  , testCase "Try workds" $ launch tryWorks
  ]

exceptionWorks :: Process ()
exceptionWorks = do
    self <- getSelfPid

    let specs = define "exception-handling" $ do
          ph0 <- phaseHandle "ph0"
          setPhase ph0 $ \(Donut _) ->
            (liftProcess $ error "foo") `catch`
              (\e -> liftProcess $ usend self (show (e::SomeException)))
          start ph0 ()

    pid <- spawnLocal $ execute () specs
    usend pid donut

    i <- expect
    assertEqual "Ph2 should fire first" "foo" i

newtype MyE = MyE String deriving (Show, Typeable, Eq, Binary)

instance Exception MyE

tryWorks :: Process ()
tryWorks = do
    self <- getSelfPid

    let specs = define "exception-handling" $ do
          ph0 <- phaseHandle "ph0"
          setPhase ph0 $ \(Donut _) -> do
            eresult <- trySome $ throwM $ MyE "failure"
            liftProcess . usend self $ case eresult of
              Left s -> case fromException s of
                Nothing -> Right ()
                Just e  -> Left (e :: MyE)
              Right () -> Right ()
          start ph0 ()

    pid <- spawnLocal $ execute () specs
    usend pid donut

    let e = Left (MyE "failure") :: Either MyE ()
    assertEqual "Exception should be caught" e =<< expect
  where
    trySome :: PhaseM g l () -> PhaseM g l (Either SomeException ())
    trySome = try

testsDefaultHandler :: (Process () -> IO ()) -> TestTree
testsDefaultHandler launch = testGroup "State"
  [ testCase "Default handler works"  $ launch defaultHandlerWorks ]

defaultHandlerWorks :: Process ()
defaultHandlerWorks = do
    self <- getSelfPid

    let specs = do
          setDefaultHandler $ \_ _ _ _ -> do
            liftProcess $ usend self ("default"::String)
          defineSimple "defaultHandler" $ \(Donut _) -> do
            liftProcess $ usend self ("rule"::String)

    pid <- spawnLocal $ execute () specs
    usend pid donut
    assertEqual "rule handled" ("rule"::String) =<< expect
    usend pid donut
    assertEqual "rule handled" ("rule"::String) =<< expect
    usend pid (persistMessage UUID.nil (3::Int))
    assertEqual "default handler" ("default"::String) =<< expect

testsPhaseIf :: (Process () -> IO ()) -> TestTree
testsPhaseIf launch = testGroup "setPhaseIf"
  [ testCase "setPhaseIf doesn't fail on partial pattern"  $ launch setPhaseIfPartial
  ]

data AB = A | B deriving (Eq, Show, Generic, Typeable)

setPhaseIfPartial :: Process ()
setPhaseIfPartial = do
    self <- getSelfPid

    let specs = define "exception-handling" $ do
          ph0 <- phaseHandle "ph0"
          setPhaseIf ph0 (\A () () -> return $ Just ()) $ const $ liftProcess $ usend self "foo"
          start ph0 ()

    pid <- spawnLocal $ execute () specs
    link pid
    usend pid A
    usend pid B

    i <- expect
    assertEqual "Handle second message" "foo" i

testsSMessage :: (Process () -> IO ()) -> TestTree
testsSMessage launch = testGroup "PersistedMessage"
  [ testCase "PersistMessage works" $ launch stableMessageWorks
  , testCase "PersistMessage decode . encode = id" $ launch persistEncodeDecode
  , testCase "SafeCopy migrate PersistMessage works" $ launch migrateWorks
  ]

stableMessageWorks :: Process ()
stableMessageWorks = do
    self <- getSelfPid

    let specs = define "persist-message" $ do
          ph0 <- phaseHandle "ph0"
          setPhase ph0 $ \Baz{} -> liftProcess $ usend self "foo"
          start ph0 ()

    pid <- spawnLocal $ execute () $ do
             setDefaultHandler $ \_ _ _ _ -> do
               liftProcess $ usend self ("default"::String)
             specs
    link pid
    let a = Baz 3
    usend pid $ persistMessage UUID.nil a
    assertEqual "Handle first message" "foo" =<< expect
    usend pid $ persistMessage UUID.nil B
    assertEqual "Second message was not processed" "default" =<< expect

persistEncodeDecode :: Process ()
persistEncodeDecode = do
  let content = SomeType_v0 "a b c d"
      recoded = Data.PersistMessage.unwrapMessage $ persistMessage UUID.nil content
  assertEqual "unwrapMessage . persistMessage … = Just" (Just content) recoded

data SomeType_v0 = SomeType_v0 String
  deriving (Eq, Show, Generic)

data SomeType = SomeType String String
  deriving (Eq, Show, Generic)

instance Migrate SomeType where
  type MigrateFrom SomeType = SomeType_v0
  migrate (SomeType_v0 s) = SomeType s "bar"

migrateWorks :: Process ()
migrateWorks = do
  self <- getSelfPid
  let specs = define "persist-message-migrate" $ do
        ph0 <- phaseHandle "ph0"
        setPhase ph0 $ \m@(SomeType{}) -> liftProcess $ usend self m
        start ph0 ()
  pid <- spawnLocal $ execute () $ do
    setDefaultHandler $ \_ _ _ _ -> do
      liftProcess $ usend self ("default" :: String)
    specs
  link pid
  let oldContent = SomeType_v0 "foo"
      newContent = migrate oldContent :: SomeType
      oldMsg = persistMessage UUID.nil oldContent
      newMsg = persistMessage UUID.nil newContent
      sendMsg = oldMsg { persistMessagePrint = persistMessagePrint newMsg }
  usend pid sendMsg
  assertEqual "Handle migrated message" newContent =<< expect
  usend pid $ persistMessage UUID.nil B
  assertEqual "Second message was not processed" "default" =<< expect

deriveSafeCopy 0 'base ''AB
deriveSafeCopy 0 'base ''Baz

deriveSafeCopy 0 'base ''SomeType_v0
deriveSafeCopy 1 'extension ''SomeType
