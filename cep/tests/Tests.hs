{-# LANGUAGE ScopedTypeVariables, GeneralizedNewtypeDeriving, RankNTypes #-}

module Tests where

import Control.Distributed.Process
import Control.Monad (replicateM)
import Data.Binary (Binary)
import Data.Typeable
import Data.List (sort)
import Data.IORef

import Test.Tasty
import Test.Tasty.HUnit (testCase)
import qualified Test.Tasty.HUnit as HU

import Network.CEP

newtype Donut = Donut () deriving Binary

newtype Foo = Foo { unFoo :: Int } deriving (Show, Binary)
newtype Baz = Baz Int deriving (Show, Binary)

donut :: Donut
donut = Donut ()

newtype Res a = Res a deriving (Eq, Show, Binary)

data GlobalState = GlobalState

assert :: Bool -> Process ()
assert True = return ()
assert _    = error "assertion failure"

assertEqual :: (Show a, Eq a) => String -> a -> a -> Process ()
assertEqual s i r = liftIO $ HU.assertEqual s i r

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
  ]

testsGlobal :: (Process () -> IO ()) -> TestTree
testsGlobal launch = localOption (mkTimeout 500000) $ testGroup "State"
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
    Res (i :: Int) <- expect
    assert $ i == 2

globalIsGlobal :: Process ()
globalIsGlobal = do
    self <- getSelfPid
    pid  <- spawnLocal $ execute (1 :: Int) $ do
      define "rule" $ do
        ph1 <- phaseHandle "state-1"
        ph2 <- phaseHandle "state-2"
        ph3 <- phaseHandle "state-3"

        setPhase ph1 $ \(Foo{}) -> do
          fork NoBuffer $ continue ph2
          fork NoBuffer $ continue ph2
          stop

        setPhase ph2 $ \(Donut _) -> do
          modify Global (+1)
          continue ph3

        setPhase ph3 $ \(Donut _) -> do
          i <- get Global
          liftProcess $ usend self (Res i)
        start ph1 ()

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
testsSwitch launch = localOption (mkTimeout 500000) $ testGroup "Switch"
  [ testCase "Switching is working" $ launch switchIsWorking
  , testCase "Switch execute one rule" $ launch switchTerminate
  , testCase "Call continue in switch"  $ launch switchContinue
  , testCase "Call suspend in switch"   $ launch switchSuspend
  , testCase "Call stop in switch"  $ launch switchStop
  , testCase "Failed rules modify local state"
             $ launch $ switchFailedRulesDontChangeState Local True
  , testCase "Failed rules modify global state"
             $ launch $ switchFailedRulesDontChangeState Global True
  ]

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
    assert =<< receiveWait [ match (\Foo{} -> return True)
                           , matchAny (\_ -> return False)
                           ]
    usend pid (Foo 2) -- XXX: tick
    assert =<< receiveWait [ match (\(Res s) -> return $ s == "ph1")
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

switchFailedRulesDontChangeState :: Scope Int Int Int -> Bool -> Process ()
switchFailedRulesDontChangeState l b = do
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
    assertEqual "failed rules should not modify local state" b (i==9)

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
testsFork launch = localOption (mkTimeout 500000) $ testGroup "Fork"
  [ testCase "Peek shift is working" $ launch forkIsWorking
  , testCase "Fork copies local state" $ launch forkCopyLocalState
  , testCase "Fork copies curent buffer" $ launch forkCopyLocalBuffer
  , testCase "Fork do not copy other rules" $ launch forkDontCopyOtherRules
  , testCase "Fork increments number of SMs" $ launch forkIncrSMs
  ]

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
          liftProcess $ usend self i
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
  [ testCase "Init rule is working" $ launch initRuleIsWorking ]

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

        setPhase ph1 $ \(Donut _) -> do
          i <- get Global
          liftProcess $ usend self (Res i)

        start ph1 ()

    usend pid donut
    usend pid donut
    Res (i :: Int) <- expect
    assert $ i == 4

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
    let [_,_,last_run] = infos
        RunInfo _ (RulesBeenTriggered [rinfo]) = last_run
        RuleInfo _ _ (ExecutionReport _ _ exe) = rinfo
        [_, _, SuccessExe ph _ _, _, _]        = exe

    assertEqual "should not lose msgs" "ph2" (stackPhaseInfoPhaseName ph)

forkIncrSMs :: Process ()
forkIncrSMs = do
  let defs = define "fork-it" $ do
        ph <- phaseHandle "phase-1"

        directly ph $ fork CopyBuffer $ return ()

        start ph ()
      start_engine = cepEngine () defs

  (RunInfo _ res, _) <- stepForward tick start_engine
  let RulesBeenTriggered res' = res
  assertEqual "length of info is 2" 4 (length res')
  let (RuleInfo _ _ rep:_)           = res'
      ExecutionReport spawned term _ = rep

  assert (spawned == term && spawned == 2)

testsExecution :: (Process () -> IO ()) -> TestTree
testsExecution launch = testGroup "Execution properties"
  [ -- localOption (mkTimeout 500000) $ testCase "Loop do not prevent cep from working" $ launch loopWorks
    localOption (mkTimeout 500000) $ HU.testCaseSteps "Parallel rule execution"
                                   $ launch . testSequenceRules
  , localOption (mkTimeout 500000) $ testCase "State machine runs to the end with helper"
                                   $ launch $ testConsumption 2
  , localOption (mkTimeout 500000) $ testCase "State machine runs to the end with another rule"
                                   $ launch $ testConsumption 1
  , localOption (mkTimeout 500000) $ testCase "State machine runs to the end"
                                   $ launch $ testConsumption 0
  , localOption (mkTimeout 500000) $ testCase "Direct rule is always executed"
                                   $ launch $ testConsumptionDirect
  , localOption (mkTimeout 500000) $ testCase "Stop works"
                                   $ launch $ testStopWorks
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
testSequenceRules step = do
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
    liftIO $ step "normal order"
    usend pid donut
    assertEqual "phase1" "ph1" =<< expect
    usend pid (Foo 1)
    assertEqual "phase2" "ph2-1" =<< expect
    usend pid donut
    assertEqual "phase1" "ph1" =<< expect
    usend pid (Foo 2)
    assertEqual "phase2" "ph2-2" =<< expect
    liftIO $ step "mixed order"
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
    [ localOption (mkTimeout 500000) $ testCase "CEP should forward events"
                                     $ launch testSimpleSub
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
