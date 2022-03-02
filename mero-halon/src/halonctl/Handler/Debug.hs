{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Copyright : (C) 2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

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
import           Data.Maybe (catMaybes)
import           Data.Semigroup ((<>))
import           Data.String (IsString, fromString)
import           Data.Text (Text)
import qualified Options.Applicative as O
import           System.Exit (die)
import           Text.Printf (printf)

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
  | MSdev D.SelectSdev ModifySdev
  | MPool SelectPool ModifyPool
  deriving Show

-- XXX Move to Pretty module? <<<<<<<
pfield :: Show a => String -> a -> String
pfield name val = printf "  %s: %s\n" name (show val)

plist :: Show a => String -> [a] -> String
plist name xs = if null xs then "" else pfield name xs

pmaybe :: Show a => String -> Maybe a -> String
pmaybe name mval = maybe "" (pfield name) mval
-- XXX >>>>>>>

run :: [NodeId] -> Options -> Process ()
-- query
run nids (OQuery (QDrive select QDriveInfo)) =
    let mkReq = D.DebugQueryDriveInfo . D.QueryDriveInfoReq select
        prettyH0Sdev D.DebugH0Sdev{..} =
            show dhsSdev ++ "\n"
             ++ plist "ids" dhsIds
             ++ pmaybe "status" dhsStatus
             ++ plist "attrs" dhsAttrs
             ++ pmaybe "slot" dhsSlot
             ++ pmaybe "replaced-by" dhsReplacedBy
        prettyM0Drive D.DebugM0Drive{..} =
            show dmdDrive ++ "\n"
             ++ pfield "is-replaced" dmdIsReplaced
        prettyM0Sdev D.DebugM0Sdev{..} =
            show dmsSdev ++ "\n"
             ++ pmaybe "state" dmsState
             ++ pmaybe "slot" dmsSlot
    in clusterCommand nids Nothing mkReq $ \case
        D.QueryDriveInfo info -> liftIO . mapM_ putStr $ catMaybes
          [ prettyH0Sdev <$> D.dsiH0Sdev info
          , prettyM0Drive <$> D.dsiM0Drive info
          , prettyM0Sdev <$> D.dsiM0Sdev info ]
        D.QueryDriveInfoError err -> liftIO (die err)
run _ (OQuery (QPool _ _)) = error "XXX IMPLEMENTME"
-- modify
run nids (OModify (MDrive select (ModifyDrive newState))) =
    let mkReq = D.DebugModifyDriveState . D.ModifyDriveStateReq select newState
    in clusterCommand nids Nothing mkReq $ \case
        D.ModifyDriveStateOK -> pure ()
        D.ModifyDriveStateError err -> liftIO (die err)
run nids (OModify (MSdev select (ModifySdev newState))) =
    let mkReq = D.DebugModifySdevState . D.ModifySdevStateReq select newState
    in clusterCommand nids Nothing mkReq $ \case
        D.ModifySdevStateOK -> pure ()
        D.ModifySdevStateError err -> liftIO (die err)
run _ (OModify (MPool _ _)) = error "XXX IMPLEMENTME"

parser :: O.Parser Options
parser = O.hsubparser
  $ command' "print" (OQuery <$> parseQuery) "Query resource(s)"
 <> command' "set" (OModify <$> parseModify) "Modify resource(s)"
  where
   parseQuery = O.hsubparser $ foldMap cmdQuery targets
   parseModify = O.hsubparser $ foldMap cmdModify targets
   cmdQuery (name, Just p, _) = command' name p ("Query " ++ name)
   cmdQuery _ = mempty
   cmdModify (name, _, Just p) = command' name p ("Modify " ++ name)
   cmdModify _ = mempty
   targets = [ ("drive", Just parseQDrive, Just parseMDrive)
             , ("sdev", Nothing, Just parseMSdev)
             , ("pool", Just parseQPool, Just parseMPool) ]

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

data QueryDrive = QDriveInfo deriving Show

newtype ModifyDrive = ModifyDrive D.StateOfDrive deriving Show

parseQDrive :: O.Parser Query
parseQDrive = QDrive <$> parseSelectDrive <*> pure QDriveInfo

parseSelectDrive :: O.Parser D.SelectDrive
parseSelectDrive = D.SelectDrive <$> parseDriveId

parseDriveId :: O.Parser D.DriveId
parseDriveId = serial <|> wwn <|> enclSlot
  where
    mkHelp desc factsField = O.help $
        desc ++ " (`" ++ factsField ++ "' in facts.yaml)"
    serial = D.DriveSerial
        <$> strOption ( O.long "serial"
                     <> O.metavar "STR"
                     <> mkHelp "Serial number" "m0d_serial" )
    wwn = D.DriveWwn
        <$> strOption ( O.long "wwn"
                     <> O.metavar "STR"
                     <> mkHelp "World Wide Name" "m0d_wwn" )
    enclSlot = D.DriveEnclSlot
        <$> strOption ( O.long "enclosure"
                     <> O.metavar "STR"
                     <> mkHelp "Enclosure identifier" "enc_id" )
        <*> O.option O.auto
                ( O.long "slot"
               <> O.metavar "INT"
               <> mkHelp "Slot within the enclosure" "m0d_slot" )

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
-- Sdev (storage device)

newtype ModifySdev = ModifySdev D.StateOfSdev deriving Show

parseSelectSdev :: O.Parser D.SelectSdev
parseSelectSdev = D.SelectSdev <$> parseDriveId  -- XXX s/Drive/Sdev/ ?

parseMSdev :: O.Parser Modify
parseMSdev = MSdev <$> parseSelectSdev <*> parseModifySdev

parseModifySdev :: O.Parser ModifySdev
parseModifySdev = ModifySdev <$> parseStateOfSdev

parseStateOfSdev :: O.Parser D.StateOfSdev
parseStateOfSdev = O.argument (reader supported)
  ( O.metavar "STATE"
 <> O.help ("Supported values: " ++ quoted supported) )
  where
    supported = [ ("ONLINE",   D.SdevOnline)
                , ("FAILED",   D.SdevFailed)
                , ("REPAIRED", D.SdevRepaired) ]

----------------------------------------------------------------------
-- Pool

data SelectPool = SelectPool { _spFid :: Text } deriving Show

data QueryPool = QPoolInfo deriving Show

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
parseQPool = QPool <$> parseSelectPool <*> pure QPoolInfo

parseSelectPool :: O.Parser SelectPool
parseSelectPool = SelectPool <$> strOption ( O.long "fid"
                                          <> O.metavar "STR"
                                          <> O.help "Pool fid" )

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
