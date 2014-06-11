{-# LANGUAGE Arrows #-}

import Control.Wire hiding (as, (.))
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Maybe (maybeToList)
import Data.List (foldl')

newtype MachineId = MachineId Int deriving (Eq, Ord, Show)
data Heartbeat = Heartbeat MachineId ClockTime deriving (Show)
newtype ClockTime = ClockTime Int deriving (Eq, Ord, Show)

data Input = ITick ClockTime
           | IHeartbeat Heartbeat deriving Show

data Output = ODied [MachineId] deriving Show

diffTime :: ClockTime -> ClockTime -> ClockTime
diffTime (ClockTime t1) (ClockTime t2) = ClockTime (t1 - t2)

mostRecentHeartbeat :: Wire e m [Heartbeat] (Map.Map MachineId ClockTime)
mostRecentHeartbeat = accum1 (foldl' (\d' (Heartbeat machine t) ->
                                       Map.insert machine t d'))
                             Map.empty

noBeatInLast :: Monad m =>
                ClockTime -> Wire e m (Map.Map MachineId ClockTime, ClockTime)
                                      (Set.Set MachineId)
noBeatInLast maxTime = proc (d, now) -> do
  let tooLongAgo p = now `diffTime` p >= maxTime
  returnA -< Map.keysSet (Map.filter tooLongAgo d)

timeOfInput :: Input -> ClockTime
timeOfInput (ITick t) = t
timeOfInput (IHeartbeat (Heartbeat _ t)) = t

heartbeatOfInput :: Input -> Maybe Heartbeat
heartbeatOfInput (ITick _) = Nothing
heartbeatOfInput (IHeartbeat h) = Just h

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

flow :: Monad m => Wire e m Input Output
flow = proc input -> do
  heartbeats <- arr (maybeToList . heartbeatOfInput) -< input
  m <- mostRecentHeartbeat -< heartbeats
  let tick = timeOfInput input
  arr (ODied . Set.toList) <<< noBeatInLast (ClockTime 5) -< (m, tick)

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
  let ticks = [ ITick (ClockTime 1)
              , IHeartbeat (Heartbeat (MachineId 1) (ClockTime 2))
              , ITick (ClockTime 20)
              , ITick (ClockTime 30)
              ]

  runWire flow ticks
