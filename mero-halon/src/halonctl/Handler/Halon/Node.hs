{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE StrictData      #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Module    : Handler.Halon.Node
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Halon.Node
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Monad (unless)
import           Data.Foldable (for_)
import           Data.Function (fix)
import           Data.List
import           Data.Monoid (mconcat)
import           Data.Traversable
import           HA.Logger
import qualified Handler.Halon.Node.Add as Add
import qualified Handler.Halon.Node.Remove as Remove
import qualified Options.Applicative as Opt
import           Options.Applicative.Extras (command')
import           System.Exit (exitFailure)
import           System.IO (hPutStrLn, stderr)
import           Text.Printf (printf)

-- | Possible node commands.
data Options
  = SilenceSubsystem String
    -- ^ Stop trace logs for subsystem
  | VerboseSubsystem String
    -- ^ Start trace logs for subsystem
  | Add Add.Options
  | Remove Remove.Options
  deriving (Eq,Show)

-- | Parser for 'NodeCmd'.
parser :: Opt.Parser Options
parser = Opt.hsubparser $ mconcat
    [ command' "disable-traces" silence "Disable trace logs for subsystem."
    , command' "enable-traces"  verbose "Enable trace logs for subsystem."
    , command' "add" (Add <$> Add.parser) "Add node to system."
    , command' "remove" (Remove <$> Remove.parser) "Remove node from system."
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
run :: [NodeId] -> Options -> Process ()
run nids (Add opts) = Add.run nids opts >>= \case
  [] -> return ()
  fails -> liftIO $ do
    for_ fails $ \(n, reason) -> do
      hPutStrLn stderr $ printf "%s failed to start: %s" (show n) reason
    exitFailure
run nids (Remove opts) = Remove.run nids opts
run nids (SilenceSubsystem s) = runSubsystem nids $ $(mkClosure 'silenceLogger) s
run nids (VerboseSubsystem s) = runSubsystem nids $ $(mkClosure 'verboseLogger) s

runSubsystem :: [NodeId] -> Closure (Process ()) -> Process ()
runSubsystem nids cmd = do
  refs <- for nids $ \node -> spawnAsync node cmd
  flip fix refs $ \loop st -> unless (null st) $
    receiveWait [ match $ \(DidSpawn r p) -> do
      let n = processNodeId p
      say $ show n ++ " done."
      loop (delete r st) ]
