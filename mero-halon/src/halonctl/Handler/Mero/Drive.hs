{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Drive
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : All rights reserved.
module Handler.Mero.Drive
  ( parser
  , Options(..)
  , run
  ) where

import           Control.Distributed.Process
import           Data.Foldable
import           Data.Monoid ((<>))
import           HA.RecoveryCoordinator.Castor.Commands.Events
import           HA.Resources.Castor (Enclosure_XXX1(..), Slot_XXX1(..))
import           Handler.Mero.Helpers (clusterCommand)
import           Options.Applicative
import qualified Options.Applicative as Opt
import qualified Options.Applicative.Extras as Opt
import           System.Exit (exitFailure)

parser :: Parser Options
parser = asum
     [ Opt.subparser (command "update-presence"
        $ Opt.withDesc parseDrivePresence "Update information about drive presence")
     , Opt.subparser (command "update-status"
        $ Opt.withDesc parseDriveStatus "Update drive status")
     , Opt.subparser (command "new-drive"
        $ Opt.withDesc parseDriveNew "create new drive")
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

parseSlot :: Parser Slot_XXX1
parseSlot = Slot_XXX1
   <$> (Enclosure_XXX1 <$>
         strOption (mconcat [ long "slot-enclosure"
                            , help "index of the drive's enclosure"
                            , metavar "NAME"
                            ]))
   <*> option auto (mconcat [ long "slot-index"
                            , help "index of the drive's slot"
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
  = DrivePresence String Slot_XXX1 Bool Bool
  | DriveStatus   String Slot_XXX1 String
  | DriveNew      String String
  deriving (Eq, Show)

run :: [NodeId] -> Options -> Process ()
run nids (DriveStatus serial slot@(Slot_XXX1 enc _) status) =
  clusterCommand nids Nothing (CommandStorageDeviceStatus serial slot status "NONE") $ \case
    StorageDeviceStatusErrorNoSuchDevice -> liftIO $ do
      putStrLn $ "Unkown drive " ++ serial
    StorageDeviceStatusErrorNoSuchEnclosure -> liftIO $ do
      putStrLn $ "can't find an enclosure " ++ show enc ++ " or node associated with it"
    StorageDeviceStatusUpdated -> liftIO $ do
      putStrLn $ "Command executed."
run nids (DrivePresence serial slot@(Slot_XXX1 enc _) isInstalled isPowered) =
  clusterCommand nids Nothing (CommandStorageDevicePresence serial slot isInstalled isPowered) $ \case
    StorageDevicePresenceErrorNoSuchDevice -> liftIO $ do
      putStrLn $ "Unknown drive " ++ serial
      exitFailure
    StorageDevicePresenceErrorNoSuchEnclosure -> liftIO $ do
      putStrLn $ "No enclosure " ++ show enc
      exitFailure
    StorageDevicePresenceUpdated -> liftIO $ do
      putStrLn $ "Command executed."
run nids (DriveNew serial path) =
  clusterCommand nids Nothing (CommandStorageDeviceCreate serial path) $ \case
   StorageDeviceErrorAlreadyExists -> liftIO $ do
     putStrLn $ "Drive already exists: " ++ serial
     exitFailure
   StorageDeviceCreated -> liftIO $ do
     putStrLn $ "Storage device created."
