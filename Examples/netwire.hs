{-# LANGUAGE Arrows #-}

import Control.Wire hiding (as, (.))
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Maybe (maybeToList)
import Data.List (foldl')

type ClockTime = Double

newtype MachineId = MachineId Int deriving (Eq, Ord, Show)
data Heartbeat = Heartbeat MachineId ClockTime deriving (Show)
data Timeout = Timeout { timedOut :: MachineId
                       , reportedBy :: MachineId
                       , timeoutTime :: ClockTime } deriving (Show)

data Input = ITick ClockTime
           | IHeartbeat Heartbeat
           | ITimeout Timeout deriving Show

data Output = Output { odied ::  [MachineId] 
                     , avgDeadTime :: ClockTime } deriving Show

accum1Many :: (b -> a -> b) -> b -> Wire e m [a] b
accum1Many f = accum1 (foldl' f)

mostRecentHeartbeat :: Wire e m [Heartbeat] (Map.Map MachineId ClockTime)
mostRecentHeartbeat = accum1Many (\d' (Heartbeat machine t) ->
                                   Map.insert machine t d')
                                 Map.empty

noBeatInLast :: Monad m =>
                ClockTime -> Wire e m (Map.Map MachineId ClockTime, ClockTime)
                                      (Set.Set MachineId)
noBeatInLast maxTime = proc (d, now) -> do
  let tooLongAgo p = now - p >= maxTime
  returnA -< Map.keysSet (Map.filter tooLongAgo d)

timeOfInput :: Input -> ClockTime
timeOfInput (ITick t) = t
timeOfInput (IHeartbeat (Heartbeat _ t)) = t
timeOfInput (ITimeout t) = timeoutTime t

heartbeatOfInput :: Input -> Maybe Heartbeat
heartbeatOfInput (IHeartbeat h) = Just h
heartbeatOfInput _ = Nothing

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
  let heartbeats = (maybeToList . heartbeatOfInput) input

  m <- mostRecentHeartbeat -< heartbeats
  let theTime = timeOfInput input

  dt <- stepSize -< theTime

  deadMachines <- arr Set.toList <<< noBeatInLast 5 -< (m, theTime)

  totalDeadTime <- sum' -< thisDeadTime deadMachines dt

  let avgDeadTime' = totalDeadTime / theTime

  returnA -< Output { odied = deadMachines, avgDeadTime = avgDeadTime' }

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
  let ticks = [ ITick 1
              , IHeartbeat (Heartbeat (MachineId 1) 2)
              , ITick 20
              , ITick 30
              ]

  runWire flow ticks
