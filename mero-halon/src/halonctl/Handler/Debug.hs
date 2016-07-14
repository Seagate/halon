-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Querying Halon debugging information.

module Handler.Debug
  ( DebugOptions
  , parseDebug
  , debug
  ) where

import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Producer (promulgateEQ)
import HA.EventQueue.Types
  ( EQStatResp(..)
  , EQStatReq(..)
  )
import HA.Resources

import Lookup

import Control.Distributed.Process
import Control.Monad (forM_, join)

import Data.Monoid ((<>))

import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import Text.Printf (printf)

data DebugOptions =
    EQStats EQStatsOptions
  deriving (Eq, Show)

parseDebug :: O.Parser DebugOptions
parseDebug =
  ( EQStats <$> O.subparser ( O.command "eq" (O.withDesc parseEQStatsOptions
        "Print EQ statistics." )))

debug :: [NodeId] -> DebugOptions -> Process ()
debug nids dbgo = case dbgo of
  EQStats x -> eqStats nids x

data EQStatsOptions = EQStatsOptions Int -- ^ Timeout for querying EQ
  deriving (Eq, Show)

-- | Print Event Queue statistics.
eqStats :: [NodeId] -> EQStatsOptions -> Process ()
eqStats nids (EQStatsOptions t) = do
    self <- getSelfPid
    eqs <- findEQFromNodes t nids
    forM_ eqs $ \eq -> do
      nsendRemote eq eventQueueLabel $ EQStatReq self
    expect >>= liftIO . display
  where
    display (EQStatResp queueSize) =
      putStrLn $ printf "EQ size: %d" queueSize
    display EQStatRespCannotBeFetched =
      putStrLn "Cannot fetch EQ stats."


parseEQStatsOptions :: O.Parser EQStatsOptions
parseEQStatsOptions = EQStatsOptions
  <$> O.option O.auto (
        O.metavar "TIMEOUT (μs)"
        <> O.long "eqt-timeout"
        <> O.value 1000000
        <> O.help ("Time to wait from a reply from the EQT when" ++
                  " querying the location of an EQ.")
      )
