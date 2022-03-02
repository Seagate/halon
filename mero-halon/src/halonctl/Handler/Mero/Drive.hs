{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Drive
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Drive
  ( parser
  , Options(..)
  , run
  ) where

import           Control.Distributed.Process hiding (die)
import           Data.Foldable
import           Data.Monoid ((<>))
import           HA.RecoveryCoordinator.Castor.Commands.Events
import qualified HA.Resources.Castor as Castor
import           Handler.Mero.Helpers (clusterCommand)
import           Options.Applicative
import qualified Options.Applicative as Opt
import           Options.Applicative.Extras (command')
import           System.Exit (die)

parser :: Parser Options
parser = asum
     [ Opt.hsubparser (command' "update-presence" parseDrivePresence
                       "Update information about drive presence")
     , Opt.hsubparser (command' "update-status" parseDriveStatus
                       "Update drive status")
     , Opt.hsubparser (command' "new-drive" parseDriveNew "create new drive")
     ]
   where
     parseDriveNew :: Parser Options
     parseDriveNew = DriveNew <$> optSerial <*> optPath

     parseDrivePresence :: Parser Options
     parseDrivePresence = DrivePresence
        <$> optSerial
        <*> parseSlot
        <*> Opt.switch (long "is-installed" <>
                        help "Mark drive as installed")
        <*> Opt.switch (long "is-powered" <>
                        help "Mark drive as powered")
     parseDriveStatus :: Parser Options
     parseDriveStatus = DriveStatus
        <$> optSerial
        <*> parseSlot
        <*> strOption (long "status"
                      <> metavar "[EMPTY|OK]"
                      <> help "Set drive status")


optSerial :: Parser String
optSerial = strOption $ mconcat
   [ long "serial"
   , short 's'
   , help "Drive serial number"
   , metavar "SERIAL"
   ]


parseSlot :: Parser Castor.Slot
parseSlot = Castor.Slot
   <$> (Castor.Enclosure <$>
         strOption (mconcat [ long "slot-enclosure"
                            , help "identifier of the drive's enclosure (`enc_id' in facts.yaml)"
                            , metavar "NAME"
                            ]))
   <*> option auto (mconcat [ long "slot-index"
                            , help "index of the drive's slot (`m0d_slot' in facts.yaml)"
                            , metavar "INT"
                            ])


optPath :: Parser String
optPath = strOption $ mconcat
  [ long "path"
  , short 'p'
  , help "Drive path"
  , metavar "PATH"
  ]


data Options
  = DrivePresence String Castor.Slot Bool Bool
  | DriveStatus   String Castor.Slot String
  | DriveNew      String String
  deriving (Eq, Show)


run :: [NodeId] -> Options -> Process ()
run nids (DriveStatus serial slot@(Castor.Slot enc _) status) =
  clusterCommand nids Nothing (CommandStorageDeviceStatus serial slot status "NONE") $ \case
    StorageDeviceStatusErrorNoSuchDevice -> liftIO $ do
      putStrLn $ "Unkown drive " ++ serial
    StorageDeviceStatusErrorNoSuchEnclosure -> liftIO $ do
      putStrLn $ "can't find an enclosure " ++ show enc ++ " or node associated with it"
    StorageDeviceStatusUpdated -> liftIO $ putStrLn "Command executed."
run nids (DrivePresence serial slot@(Castor.Slot enc _) isInstalled isPowered) =
  clusterCommand nids Nothing (CommandStorageDevicePresence serial slot isInstalled isPowered) $ \case
    StorageDevicePresenceErrorNoSuchDevice -> liftIO . die $ "Unknown drive " ++ serial
    StorageDevicePresenceErrorNoSuchEnclosure -> liftIO . die $ "No enclosure " ++ show enc
    StorageDevicePresenceUpdated -> liftIO $ putStrLn "Command executed."
run nids (DriveNew serial path) =
  clusterCommand nids Nothing (CommandStorageDeviceCreate serial path) $ \case
   StorageDeviceErrorAlreadyExists -> liftIO . die $ "Drive already exists: " ++ serial
   StorageDeviceCreated -> liftIO $ do
     putStrLn $ "Storage device created."
