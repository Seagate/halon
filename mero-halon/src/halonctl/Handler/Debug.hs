{-# LANGUAGE LambdaCase #-}

-- |
-- Copyright : (C) 2018 Seagate Technology Limited.
-- License   : All rights reserved.

module Handler.Debug
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Applicative ((<|>))
import           Control.Distributed.Process (NodeId, Process)
import           Control.Monad.IO.Class (liftIO)
import           Data.Foldable (find)
import           Data.List (intercalate)
import           Data.Semigroup ((<>))
import           Data.String (IsString, fromString)
import           Data.Text (Text)
import qualified Options.Applicative as O
import           System.Exit (die)

import qualified HA.RecoveryCoordinator.RC.Events.Debug as D
import           Handler.Mero.Helpers (clusterCommand) -- XXX TODO: s/Mero\.//
import           Options.Applicative.Extras (command')

data Options = OQuery Query | OModify Modify deriving Show

data Query
  = QDrive D.SelectDrive QueryDrive
  | QPool SelectPool QueryPool
  deriving Show

data Modify
  = MDrive D.SelectDrive ModifyDrive
  | MPool SelectPool ModifyPool
  deriving Show

run :: [NodeId] -> Options -> Process ()
run nids (OQuery (QDrive select QDriveState)) =
    let mkReq = D.QueryDriveState . D.QueryDriveStateReq select
    in clusterCommand nids Nothing mkReq $ \case
        D.QDriveState st -> liftIO . putStrLn $ "XXX " ++ show st
        D.QDriveStateNoStorageDeviceError ->
            liftIO $ die "No such storage device"
run nids (OModify (MDrive select (ModifyDrive newState))) =
    let mkReq = D.ModifyDriveState . D.ModifyDriveStateReq select newState
    in clusterCommand nids Nothing mkReq $ \case
        D.MDriveStateOK -> liftIO . putStrLn $ "XXX OK"
        D.MDriveStateNoStorageDeviceError ->
            liftIO $ die "No such storage device"
run _ x = error $ "XXX IMPLEMENTME: " ++ show x

parser :: O.Parser Options
parser = O.hsubparser
  $ command' "print" (OQuery <$> parseQuery) "Query resource(s)"
 <> command' "set" (OModify <$> parseModify) "Modify resource(s)"
  where
   parseQuery = O.hsubparser $ foldMap cmdQuery targets
   parseModify = O.hsubparser $ foldMap cmdModify targets
   cmdQuery (name, pQuery, _) = command' name pQuery ("Query " ++ name)
   cmdModify (name, _, pModify) = command' name pModify ("Modify " ++ name)
   targets = [ ("drive", parseQDrive, parseMDrive)
             , ("pool", parseQPool, parseMPool) ]

type Supported a = [(String, a)]

reader :: Supported a -> O.ReadM a
reader supported = O.eitherReader $ \s -> case find ((s ==) . fst) supported of
    Just (_, v) -> Right v
    Nothing     -> Left $ "Unsupported value: " ++ s

quoted :: Supported a -> String
quoted = let quote s = '\'':s ++ "'"
         in intercalate ", " . map (quote . fst)

-- | XXX Once we upgrade to lts-11.22, 'strOption' won't be needed any more.
strOption :: IsString s => O.Mod O.OptionFields String -> O.Parser s
strOption = fmap fromString . O.strOption

----------------------------------------------------------------------
-- Drive

data QueryDrive = QDriveState | QDriveRelations deriving Show

newtype ModifyDrive = ModifyDrive D.StateOfDrive
  deriving Show

parseQDrive :: O.Parser Query
parseQDrive = QDrive <$> parseSelectDrive <*> parseQueryDrive

parseSelectDrive :: O.Parser D.SelectDrive
parseSelectDrive = D.SelectDrive <$> parseDriveId

parseDriveId :: O.Parser D.DriveId
parseDriveId = serial <|> wwn
  where
    serial = D.DriveSerial <$>
        strOption ( O.long "serial"
                 <> O.metavar "STR"
                 <> O.help "Serial number of the drive" )
    wwn = D.DriveWwn <$> strOption ( O.long "wwn"
                                  <> O.metavar "STR"
                                  <> O.help "World Wide Name of the drive" )

parseQueryDrive :: O.Parser QueryDrive
parseQueryDrive = O.argument (reader supported)
  ( O.metavar "QUERY"
 <> O.value QDriveState
 <> O.help ("Supported queries: " ++ quoted supported) )
  where
    supported = [ ("state",     QDriveState)
                , ("relations", QDriveRelations) ]

parseMDrive :: O.Parser Modify
parseMDrive = MDrive <$> parseSelectDrive <*> parseModifyDrive

parseModifyDrive :: O.Parser ModifyDrive
parseModifyDrive = ModifyDrive <$> parseStateOfDrive

parseStateOfDrive :: O.Parser D.StateOfDrive
parseStateOfDrive = O.argument (reader supported)
  ( O.metavar "STATE"
 <> O.help ("Supported values: " ++ quoted supported) )
  where
    supported = [ ("ONLINE", D.DriveOnline)
                , ("FAILED", D.DriveFailed)
                , ("BLANK",  D.DriveBlank) ]

----------------------------------------------------------------------
-- Pool

data SelectPool = SelectPool { _spFid :: Text } deriving Show

data QueryPool = QPoolState deriving Show

data ModifyPool
  = MPoolState StateOfPool
  | MPoolRepReb PoolRepReb
  deriving Show

data StateOfPool = PoolOnline | PoolOffline deriving Show

-- | Repair/rebalance request.
data PoolRepReb
  = RepairStart
  | RepairAbort
  | RepairQuiesce
  | RepairContinue
  | RebalanceStart
  | RebalanceAbort
  | RebalanceQuiesce
  | RebalanceContinue
  deriving Show

parseQPool :: O.Parser Query
parseQPool = QPool <$> parseSelectPool <*> parseQueryPool

parseSelectPool :: O.Parser SelectPool
parseSelectPool = SelectPool
  <$> strOption
          ( O.long "fid"
         <> O.metavar "STR"
         <> O.help "Pool fid" )

parseQueryPool :: O.Parser QueryPool
parseQueryPool = O.argument (reader supported)
  ( O.metavar "QUERY"
 <> O.value QPoolState
 <> O.help ("Supported queries: " ++ quoted supported) )
  where
    supported = [("state", QPoolState)]

parseMPool :: O.Parser Modify
parseMPool = MPool <$> parseSelectPool <*> parseModifyPool

parseModifyPool :: O.Parser ModifyPool
parseModifyPool = O.hsubparser
  $ command' "state" (MPoolState <$> parseState) "Change pool state"
 <> command' "repair" (MPoolRepReb <$> parseRepair) "Pool repair control"
 <> command' "rebalance" (MPoolRepReb <$> parseRebalance)
        "Pool rebalance control"
 where
   supportedStates = [ ("OFFLINE", PoolOffline)
                     , ("ONLINE", PoolOnline) ]
   parseState = O.argument (reader supportedStates)
       ( O.metavar "STATE"
      <> O.help ("Supported values: " ++ quoted supportedStates) )
   supportedRepairOps = [ ("start",    RepairStart)
                        , ("abort",    RepairAbort)
                        , ("quiesce",  RepairQuiesce)
                        , ("continue", RepairContinue)
                        ]
   parseRepair = O.argument (reader supportedRepairOps)
       ( O.metavar "OPERATION"
      <> O.help ("Supported values: " ++ quoted supportedRepairOps) )
   supportedRebalanceOps = [ ("start",    RebalanceStart)
                           , ("abort",    RebalanceAbort)
                           , ("quiesce",  RebalanceQuiesce)
                           , ("continue", RebalanceContinue)
                           ]
   parseRebalance = O.argument (reader supportedRebalanceOps)
       ( O.metavar "OPERATION"
      <> O.help ("Supported values: " ++ quoted supportedRebalanceOps) )
