{-# LANGUAGE Arrows #-}

import Control.Wire hiding (as, (.))
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Maybe (catMaybes)
import Data.List (foldl')
import qualified Control.Arrow as Arrow

type ClockTime = Double

newtype MachineId = MachineId Int deriving (Eq, Ord, Show)
data Heartbeat = Heartbeat MachineId ClockTime deriving (Show)
data Timeout = Timeout { report' :: Report
                       , timeoutTime :: ClockTime } deriving (Show)

data Report = Report { timedOut :: MachineId
                     , reportedBy :: MachineId } deriving (Show, Eq, Ord)

data Input = Input { clockTime :: ClockTime 
                   , eventsOfInput :: [InputEvent]
                   , rebooting :: [MachineId] } deriving Show

data InputEvent = IHeartbeat Heartbeat
                | ITimeout Timeout deriving Show

data Output = Output { odied ::  [MachineId] 
                     , avgDeadTime :: ClockTime 
                     , otimeouts :: [MachineId] } 
            deriving Show

accum1Many :: (b -> a -> b) -> b -> Wire e m [a] b
accum1Many f = accum1 (foldl' f)

mostRecentHeartbeat :: Wire e m [Heartbeat] (Map.Map MachineId ClockTime)
mostRecentHeartbeat = accum1Many (\d' (Heartbeat machine t) ->
                                   Map.insert machine t d')
                                 Map.empty

collectTimeouts :: Wire e m [Timeout] (Map.Map Report [ClockTime])
collectTimeouts = accum1Many (\d (Timeout report t) ->
                               Map.alter (append' t) report d) Map.empty

append' :: v -> Maybe [v] -> Maybe [v]
append' t m = Just $ case m of Nothing -> [t]
                               Just ts -> t:ts

concat' :: [v] -> Maybe [v] -> Maybe [v]
concat' t m = Just $ case m of Nothing -> t
                               Just ts -> t ++ ts

removeTooEarly :: ClockTime -> Map.Map a [ClockTime] -> ClockTime
                  -> Map.Map a [ClockTime]
removeTooEarly duration d now = 
  (Map.filter (not . null)
  . Map.map (filter ((> now) . (+ duration)))) d

collectFailures :: Map.Map Report [ClockTime] -> Map.Map MachineId [ClockTime]
collectFailures = foldl' (\d (k, v) -> Map.alter (concat' v) k d) Map.empty
                  . map (Arrow.first (\(Report m _) -> m))
                  . Map.toList

noBeatInLast :: Monad m =>
                ClockTime -> Wire e m (Map.Map MachineId ClockTime, ClockTime)
                                      (Set.Set MachineId)
noBeatInLast maxTime = proc (d, now) -> do
  let tooLongAgo p = now - p >= maxTime
  returnA -< Map.keysSet (Map.filter tooLongAgo d)

heartbeatOfInput :: InputEvent -> Maybe Heartbeat
heartbeatOfInput (IHeartbeat h) = Just h
heartbeatOfInput _ = Nothing

timeoutOfInput :: InputEvent -> Maybe Timeout
timeoutOfInput (ITimeout t) = Just t
timeoutOfInput _ = Nothing

manyInput :: Monad m => Wire e m a b -> Wire e m [a] [b]
manyInput w = mkGen (\s as -> do
                        (bs, w') <- go s w as
                        return (Right bs, manyInput w'))
  where go _ w' [] = return ([], w')
        go s w' (a:as) = do
          (e, w'') <- stepWire w' s a
          (bs, w''') <- go s w'' as
          let b = case e of Right r -> [r]
                            Left _  -> []
          return (b ++ bs, w''')

sum' :: Num a => Wire e m a a
sum' = accum1 (+) 0

incrementFrom :: Monad m => a -> (a -> a -> b) -> Wire e m a b
incrementFrom aStart (.-) = proc aNow -> do
  aPrevious <- delay aStart -< aNow
  returnA -< aNow .- aPrevious

stepSize :: (Num a, Monad m) => Wire e m a a
stepSize = incrementFrom 0 (-)

thisDeadTime :: [MachineId] -> ClockTime -> Double
thisDeadTime deadMachines dt = fromIntegral (length deadMachines) * dt

flow :: Monad m => Wire e m Input Output
flow = proc input -> do
  let event' = eventsOfInput input
      heartbeats = (catMaybes . map heartbeatOfInput) event'
      timeouts = (catMaybes . map timeoutOfInput) event'
      theTime = clockTime input

  m <- mostRecentHeartbeat -< heartbeats
  -- TODO: vv this actually has a space leak
  collectedTimeouts <- collectTimeouts -< timeouts
  let t = removeTooEarly 10 collectedTimeouts theTime
      reportedTimeouts = (Set.toList . Map.keysSet . collectFailures) t

  dt <- stepSize -< theTime

  deadMachines <- arr Set.toList <<< noBeatInLast 5 -< (m, theTime)

  totalDeadTime <- sum' -< thisDeadTime deadMachines dt

  let avgDeadTime' = totalDeadTime / theTime

  returnA -< Output { odied = deadMachines, avgDeadTime = avgDeadTime' 
                    , otimeouts = reportedTimeouts }


runWire :: (Show a, Show b) => Wire () IO a b -> [a] -> IO ()
runWire _ [] = return ()
runWire w (a:as) = do
        putStrLn ("-> " ++ show a)
        (e, w') <- stepWire w 0 a
        case e of Left e' -> putStrLn ("XX " ++ show (e' :: ()))
                  Right b -> putStrLn ("<- " ++ show b)
        runWire w' as

runFlow :: IO ()
runFlow = do
  let ticks = [ Input 1 [] []
              , Input 2 [IHeartbeat (Heartbeat (MachineId 1) 2)] []
              , Input 5 [ITimeout
                         (Timeout
                          (Report (MachineId 2) (MachineId 3)) 5)] []
              , Input 10 [] []
              , Input 20 [] []
              , Input 30 [] []
              ]

  runWire flow ticks
