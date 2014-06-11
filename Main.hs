{-# LANGUAGE Rank2Types #-}

import Reactive.Banana.Combinators
import Reactive.Banana.Frameworks
import Reactive.Banana.Switch
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Time.Clock
import Data.Time

newtype MachineId = MachineId Int deriving (Eq, Ord, Show)
data Heartbeat = Heartbeat MachineId Time
newtype Time = Time Int deriving (Eq, Ord, Show)

data Input = ITick Time
           | IHeartbeat Heartbeat

data Output = ODied MachineId deriving Show

diffTime :: Time -> Time -> Time
diffTime (Time t1) (Time t2) = Time (t1 - t2)

mostRecentHeartbeat :: Event t Heartbeat -> Behavior t (Map.Map MachineId Time)
mostRecentHeartbeat heartbeat = accumB Map.empty
                             (fmap (\(Heartbeat machine time)
                                    -> Map.insert machine time) heartbeat)

noBeatInLast :: Time -> Behavior t (Map.Map MachineId Time)
                -> Behavior t Time
                -> Behavior t (Set.Set MachineId)
noBeatInLast maxTime d now = Map.keysSet <$> (Map.filter <$> tooLongAgo <*> d)
  where tooLongAgo = (\n p -> n `diffTime` p >= maxTime) <$> now

timeOfInput :: Input -> Time
timeOfInput (ITick t) = t
timeOfInput (IHeartbeat (Heartbeat _ t)) = t

heartbeatOfInput :: Input -> Maybe Heartbeat
heartbeatOfInput (ITick _) = Nothing
heartbeatOfInput (IHeartbeat h) = Just h

fireSet :: Behavior t (Set.Set a) -> Event t b -> Event t a
fireSet set event = spill (fmap Set.toList (apply (fmap const set) event))

fire :: Behavior t a -> Event t b -> Event t a
fire = apply . fmap const

--flow :: Event t Input -> Event t Output
flow input = fire dead input   -- ODied <$> fireSet dead tick
  where m = mostRecentHeartbeat heartbeats
        heartbeats = filterJust (heartbeatOfInput <$> input)
        tick = fmap timeOfInput input
        lastTick = stepper (Time 0) tick
        dead = noBeatInLast (Time 10) m lastTick

--runFlow :: IO [[Output]]
runFlow = interpret flow [ [ITick (Time 1)]
                         , [IHeartbeat (Heartbeat (MachineId 1) (Time 2))]
                         , [ITick (Time 20)]
                         , [ITick (Time 30)]
                         ]

printCurrent :: Behavior t UTCTime -> Event t () -> Event t (IO ())
printCurrent time tick = fmap print (time <@ tick)

moment :: Frameworks t => AddHandler () -> Moment t (Event t (IO ()))
moment addHandlerTick = printCurrent
                        <$> fromPoll getCurrentTime
                        <*> fromAddHandler addHandlerTick

runCurrent' = do
  (addHandlerTick, handlerTick) <- newAddHandler

  let h = addHandlerTick
      runCurrent'' :: Frameworks t => Moment t ()
      runCurrent'' = moment h >>= reactimate

  eventNetwork <- compile runCurrent''

  return (eventNetwork, handlerTick)

runCurrent'' = do
  (eventNetwork, handlerTick) <- runCurrent'
  actuate eventNetwork
  return handlerTick
