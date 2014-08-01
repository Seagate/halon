-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A variety of utilities for working with Sodium events and
-- behaviours, especially those for working with a source of clock
-- time.
-- 

module FRP.Sodium.Util
       ( timeLoop
       , threadDelay'
       , samplesOver
       , integral
       , average
       , averageOver
       , periodically
       , epoch ) where

import FRP.Sodium

import Control.Applicative ((<$>))
import Control.Arrow (first)
import Control.Concurrent (threadDelay)
import Data.Time.Clock (UTCTime, NominalDiffTime, getCurrentTime, diffUTCTime)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds, posixSecondsToUTCTime)

-- | A loop that performs an IO action after a regular interval.
-- Good for pumping time events…
--
-- Note: the only guarantee made is that each call of the action will
-- be at least `period` after the previous call has finished.
-- Particularly, the delay between calls may be greater, especially if
-- the action takes a long time to run, as the time is calculated from
-- the start of the action's runtime.
timeLoop :: NominalDiffTime -> (NominalDiffTime -> IO ()) -> IO b
timeLoop period act = getCurrentTime >>= timeLoop' period act

-- | 'threadDelay' but with an unbounded 'Integer' time argument.
threadDelay' :: Integer -> IO ()
threadDelay' n
  | n <= maxInt = threadDelay $ fromIntegral n
  | otherwise   = threadDelay maxBound >> threadDelay' (n - maxInt)
  where maxInt = fromIntegral (maxBound :: Int)

timeLoop' :: NominalDiffTime -> (NominalDiffTime -> IO ()) -> UTCTime -> IO b
timeLoop' period act now = do
    now' <- getCurrentTime
    act $ diffUTCTime now' now
    threadDelay' . floor $ period * 1000000
    timeLoop' period act now'

-- TODO? this integral/average could be made more efficient by updating
-- the old version instead of recalculating

-- | Staircase integral approximation.
-- Input should be in order of *descending* x.
integral :: Fractional n => [(n, n)] -> n
integral l = sum . zipWith columnArea l $ tail l
  where columnArea (x', y') (x, y) = 0.5 * (y' + y) * (x' - x)

-- | Staircase average.
-- Input should be in order of *descending* x.
average :: Fractional n => [(n, n)] -> n
average [] = 1 / 0
average ps = integral ps / range ps
  where range [] = 0
        range xs = fst (head xs) - fst (last xs)

-- | Collect all samples of a 'Behaviour' within the past t seconds.
samplesOver :: Show a => NominalDiffTime  -- ^ Time span
            -> Behaviour UTCTime          -- ^ Time source
            -> Behaviour a                -- ^ Behaviour to sample
            -> Reactive (Behaviour [(UTCTime, a)])
samplesOver d now b = accum [] $
    snapshot (\t v -> takeWhile (new t) . ((t, v) :)) (value now) b
  where new now' (t, _) = diffUTCTime now' t < d

-- | Staircase average over a given time period.
averageOver :: (Show n, Fractional n)
            => NominalDiffTime    -- ^ Span over which to sample
            -> Behaviour UTCTime  -- ^ Time source
            -> Behaviour n        -- ^ Behaviour to be averaged
            -> Reactive (Behaviour n)
averageOver d now b
  = fmap (average . map (first $ realToFrac . utcTimeToPOSIXSeconds))
      <$> samplesOver d now b

-- | Emit an event every time a value becomes sufficiently
-- different from the previous.
periodically :: (a -> a -> Bool)  -- ^ The old and new values
             -> a                 -- ^ An initial value
             -> Behaviour a       -- ^ The source of values
             -> Reactive (Event a)
periodically p z b = filterJust <$>
    collectE (\x' x -> if p x x' then (Just x', x') else (Nothing, x)) z
      (value b)

-- | The UNIX epoch, expressed as a 'UTCTime'.
epoch :: UTCTime
epoch = posixSecondsToUTCTime 0
