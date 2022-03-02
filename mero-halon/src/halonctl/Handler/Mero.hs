{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE StrictData        #-}
-- |
-- Copyright : (C) 2015-2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Cluster-wide configuration.

module Handler.Mero
  ( Options(..)
  , parser
  , mero
  ) where

import           Control.Distributed.Process
import           Data.Monoid (mconcat)
import qualified Handler.Mero.Bootstrap as Bootstrap
import qualified Handler.Mero.Drive as Drive
import qualified Handler.Mero.Dump as Dump
import qualified Handler.Mero.Load as Load
import qualified Handler.Mero.MkfsDone as MkfsDone
import qualified Handler.Mero.Node as Node
import qualified Handler.Mero.Pool as Pool
import qualified Handler.Mero.Process as Process
import qualified Handler.Mero.Reset as Reset
import qualified Handler.Mero.Start as Start
import qualified Handler.Mero.Status as Status
import qualified Handler.Mero.Stop as Stop
import qualified Handler.Mero.Sync as Sync
import qualified Handler.Mero.Update as Update
import qualified Handler.Mero.Vars as Vars
import           Lookup (findEQFromNodes)
import qualified Options.Applicative as Opt
import           Options.Applicative.Extras (command')

data Options =
    Bootstrap Bootstrap.Options
  | Drive Drive.Options
  | Dump Dump.Options
  | Load Load.Options
  | MkfsDone MkfsDone.Options
  | Node Node.Options
  | Pool Pool.Options
  | Process Process.Options
  | Reset Reset.Options
  | Start Start.Options
  | Status Status.Options
  | Stop Stop.Options
  | Sync Sync.Options
  | Update Update.Options
  | Vars Vars.Options
  deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Opt.hsubparser $ mconcat
  [ command' "bootstrap" (Bootstrap <$> Bootstrap.parser) "Bootstrap cluster."
  , command' "drive" (Drive <$> Drive.parser) "Commands to drive"
  , command' "dump" (Dump <$> Dump.parser) "Dump embedded confd database to file."
  , command' "load" (Load <$> Load.parser) "Load initial data into the system."
  , command' "mkfs-done" (MkfsDone <$> MkfsDone.parser) "Mark all processes as finished mkfs."
  , command' "node" (Node <$> Node.parser) "Node actions"
  , command' "pool" (Pool <$> Pool.parser) "Pool commands"
  , command' "process" (Process <$> Process.parser) "Process not implemented."
  , command' "reset" (Reset <$> Reset.parser) "Reset Halon's cluster knowledge to ground state."
  , command' "start" (Start <$> Start.parser) "Start mero cluster"
  , command' "status" (Status <$> Status.parser) "Query mero-cluster status"
  , command' "stop" (Stop <$> Stop.parser) "Stop mero cluster"
  , command' "sync" (Sync <$> Sync.parser) "Force synchronisation of RG to confd servers."
  , command' "update" (Update <$> Update.parser) "Force update state of the mero objects"
  , command' "vars" (Vars <$> Vars.parser) "Control variable parameters of the halon."
  ]

-- | Run the specified cluster command over the given nodes. The nodes
-- are first verified to be EQ nodes: if they aren't, we use EQ node
-- list retrieved from the tracker instead.
mero :: [NodeId] -> Options -> Process ()
mero nids' opt = do
  -- HALON-267: if user specified a cluster command but none of the
  -- addresses we list are a known EQ, try finding EQ on our own and
  -- using that instead
  rnids <- findEQFromNodes 5000000 nids' >>= \case
    [] -> do
      say "Cluster command requested but no known EQ; trying specified nids anyway"
      return nids'
    ns -> return ns
  dispatch rnids opt
  where
    dispatch _    (Bootstrap opts) = Bootstrap.run opts
    dispatch nids (Drive opts) = Drive.run nids opts
    dispatch nids (Dump opts) = Dump.run nids opts
    dispatch nids (Load opts) = Load.run nids opts
    dispatch nids (MkfsDone opts) = MkfsDone.run nids opts
    dispatch nids (Node opts) = Node.run nids opts
    dispatch nids (Pool opts) = Pool.run nids opts
    dispatch nids (Process opts) = Process.run nids opts
    dispatch nids (Reset opts) = Reset.run nids opts
    dispatch nids (Start opts)  = Start.run nids opts
    dispatch nids (Status opts) = Status.run nids opts
    dispatch nids (Stop opts)  = Stop.run nids opts
    dispatch nids (Sync opts) = Sync.run nids opts
    dispatch nids (Update opts) = Update.run nids opts
    dispatch nids (Vars opts) = Vars.run nids opts
