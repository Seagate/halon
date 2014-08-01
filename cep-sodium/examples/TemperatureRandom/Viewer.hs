-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A viewer node that listens for average temperatures and draws them.
-- 

module Viewer where

import Types

import Control.Lens
import FRP.Sodium
import FRP.Sodium.Util
import qualified Graphics.Gloss as Gloss
import Graphics.Gloss.Interface.IO.Animate (animateIO)
import Network.CEP.Processor.Sodium

import Control.Applicative ((<$>))
import Control.Arrow ((***))
import Control.Concurrent (forkIO)
import Control.Monad (void)
import Control.Monad.Trans (liftIO)
import Data.Monoid (mappend)
import Data.Time (UTCTime, getCurrentTime, diffUTCTime)


-- | A Sodium interface to Gloss's 'Gloss.animate' primitive.
animateSodium :: Gloss.Display  -- ^ The display method
           -> Gloss.Color       -- ^ The background colour
           -> (Behaviour UTCTime -> Reactive (Behaviour Gloss.Picture))
           -> IO ()
animateSodium d c f = do
    (time, pushTime) <- sync newEvent
    now              <- getCurrentTime >>= sync . flip hold time
    picture          <- sync $ f now
    void . forkIO . timeLoop 0.05 . const $ getCurrentTime >>= sync . pushTime
    animateIO d c . const . sync $ sample picture

-- | A CEP processor that listens for AverageTemperature events and
-- plots them on a simple graph using Gloss.
viewer :: Processor s ()
viewer = do
    avg         <- fmap (^. payload) <$> subscribe
    temperature <- liftReactive $ hold 0 avg
    void . liftIO . forkIO $
      animateSodium (Gloss.InWindow "Average Temperature" (800, 600) (0, 0))
                    Gloss.white
                    (drawGraph temperature)

-- | Actually draw the graph.
drawGraph :: Behaviour AverageTemperature
          -> Behaviour UTCTime
          -> Reactive (Behaviour Gloss.Picture)
drawGraph temp time = do
    points <- fmap (plot . toPoints) <$> samplesOver 25 time temp
    _      <- listen (value points) (const $ return ())
    -- XXX
    -- The above is a workaround for
    -- https://github.com/kentuckyfriedtakahe/sodium/issues/14
    return points

-- | Convert timed events to a list of (x, y) points, with relative x.
toPoints :: [(UTCTime, AverageTemperature)] -> [(Float, Float)]
toPoints [] = []
toPoints ps@((base, _) : _) = baseline $ ps
  where baseline = map $ realToFrac . flip diffUTCTime base *** realToFrac

-- | Draw the points in their appropriate positions.
plot :: [(Float, Float)] -> Gloss.Picture
plot = Gloss.translate 0 (-400) . frame . Gloss.translate 600 0
       . Gloss.pictures . map f
  where
    f (x, y) = Gloss.translate (xscale * x) (yscale * y)
               . Gloss.color Gloss.red
               $ Gloss.rectangleWire 2 2
    xscale = 50
    yscale = 50

-- | Draw a basic frame around the points
-- (or at least an x axis at zero).
frame :: Gloss.Picture -> Gloss.Picture
frame = mappend $ Gloss.line [(-10000, 0), (10000, 0)]
