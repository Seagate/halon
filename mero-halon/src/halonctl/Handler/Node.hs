-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Node-wide configuration.
{-# LANGUAGE TemplateHaskell #-}
module Handler.Node
   ( NodeOptions
   , parseOptions
   , runNodeCmd
   ) where

import HA.Logger

import Options.Applicative as Opt
import qualified Options.Applicative.Extras as Opt

import Data.Traversable
import Data.Foldable
import Data.List
import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Monad.Fix (fix)
import Control.Monad (unless)

-- | Possible node commands.
data NodeOptions
  = SilenceSubsystem String
    -- ^ Stop trace logs for subsystem
  | VerboseSubsystem String
    -- ^ Start trace logs for subsystem
  deriving (Eq,Show)

-- | Parser for 'NodeCmd'.
parseOptions :: Opt.Parser NodeOptions
parseOptions = asum
    [ Opt.subparser
       $ Opt.command "disable-traces" $ Opt.withDesc silence "Disable trace logs for subsystem."
    , Opt.subparser
       $ Opt.command "enable-traces" $ Opt.withDesc verbose "Enable trace logs for subsystem."
    ]
  where
   subsystem = Opt.strOption $ mconcat
     [ Opt.long "subsystem"
     , Opt.short 's'
     , Opt.help "Subsystem name"
     , Opt.metavar "SUBSYTEM"
     ]
   verbose = VerboseSubsystem <$> subsystem
   silence = SilenceSubsystem <$> subsystem

-- | Node actions.
runNodeCmd :: [NodeId] -> NodeOptions -> Process ()
runNodeCmd nodes opts = do
    refs <- for nodes $ \node -> spawnAsync node cmd
    flip fix refs $ \loop st -> unless (null st) $
      receiveWait [ match $ \(DidSpawn r p) -> do
        let n = processNodeId p
        say $ show n ++ " done."
        loop (delete r st) ]
  where
   cmd = case opts of
     SilenceSubsystem s -> $(mkClosure 'silenceLogger) s
     VerboseSubsystem s -> $(mkClosure 'verboseLogger) s
