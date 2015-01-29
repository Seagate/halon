{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE TemplateHaskell    #-}
{-# LANGUAGE TypeOperators      #-}
import Data.Typeable
import GHC.Generics hiding (to)

import Prelude hiding ((.), id)
import Control.Arrow
import Control.Concurrent
import Control.Distributed.Process
import Control.Distributed.Process.Node
import Control.Exception
import Control.Lens
import Control.Monad
import Control.Wire
import Control.Wire.Unsafe.Event
import Data.Binary
import qualified Data.Set as S
import Network.Transport.TCP
import System.Random

import Network.CEP

data DriveAdded = DriveAdded Int deriving (Typeable, Generic)

instance Binary DriveAdded

data DriveDisabled = DriveDisabled Int deriving (Typeable, Generic)

instance Binary DriveDisabled

data Status = Status deriving (Typeable, Generic)

instance Binary Status

data Powerdown = Powerdown deriving (Typeable, Generic)

instance Binary Powerdown

data Powerup = Powerup deriving (Typeable, Generic)

instance Binary Powerup

data DriveRemoved = DriveRemoved Int deriving (Typeable, Generic)

instance Binary DriveRemoved

data TempDriveRemoved = TempDriveRemoved Int Int deriving (Typeable, Generic)

instance Binary TempDriveRemoved

data DriveTimeout = DriveTimeout Int deriving (Typeable, Generic)

instance Binary DriveTimeout

data DriveResetAttempt = DriveResetAttempt Int [String]
                       deriving (Typeable, Generic)

instance Binary DriveResetAttempt

data DriveReplacement = DriveReplacement Int deriving (Typeable, Generic)

instance Binary DriveReplacement

data AppState =
    AppState
    { _appStateOnlineDrives :: S.Set Int }

data Output
    = OnDriveAdded Int
    | OnDriveRemoved Int
    | OnStatus

emptyAppState :: AppState
emptyAppState = AppState S.empty

makeLenses ''AppState

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
driveAdded :: ComplexEvent s Input (Event DriveAdded)
driveAdded = decodedEvent

driveRemoved :: ComplexEvent s Input (Event DriveRemoved)
driveRemoved = decodedEvent

statusAsked :: ComplexEvent s Input (Event Status)
statusAsked = decodedEvent

--------------------------------------------------------------------------------
-- Model
--------------------------------------------------------------------------------
registerDrive :: ComplexEvent s (Event DriveAdded)
                                (Event (AppState -> AppState))
registerDrive =  mkSF_ $ fmap $ \(DriveAdded i) s ->
    s & appStateOnlineDrives %~ S.insert i

unregisterDrive :: ComplexEvent s (Event DriveRemoved)
                                  (Event (AppState -> AppState))
unregisterDrive = mkSF_ $ fmap $ \(DriveRemoved i) s ->
    s & appStateOnlineDrives %~ S.delete i

nop :: ComplexEvent s (Event a) (Event (AppState -> AppState))
nop = mkSF_ $ fmap (const id)

--------------------------------------------------------------------------------
-- Output
--------------------------------------------------------------------------------
driveAddedOutput :: ComplexEvent s (Event DriveAdded) Output
driveAddedOutput = mkPure_ go
  where
    go = event (Left ()) $ \(DriveAdded i) -> Right $ OnDriveAdded i

driveRemovedOutput :: ComplexEvent s (Event DriveRemoved) Output
driveRemovedOutput = mkPure_ go
  where
    go = event (Left ()) $ \(DriveRemoved i) -> Right $ OnDriveRemoved i


statusOutput :: ComplexEvent s (Event Status) Output
statusOutput = mkPure_ go
  where
    go = event (Left ()) $ \_ -> Right OnStatus
--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
appState :: ComplexEvent s (Event (AppState -> AppState)) (Event AppState)
appState = iterateE emptyAppState

--------------------------------------------------------------------------------
-- Handler
--------------------------------------------------------------------------------
handler :: (AppState, Output) -> CEP ()
handler (s, o) =
    case o of
        OnDriveAdded i   -> onDriveAdded i
        OnDriveRemoved i -> onDriveRemoved i
        OnStatus         -> onStatus s

onDriveAdded :: Int -> CEP ()
onDriveAdded i = liftIO $ putStrLn $ "Drive " ++ show i ++ " has been added."

onDriveRemoved :: Int -> CEP ()
onDriveRemoved i = liftIO $ putStrLn $ "Drive " ++ show i ++ " has been removed."

onStatus :: AppState -> CEP ()
onStatus s = liftIO $ do
    putStrLn "-------------------------------------"
    putStrLn "               STATUS                "
    putStrLn "-------------------------------------"
    let cnt    = s ^. appStateOnlineDrives.to S.size
        online = s ^. appStateOnlineDrives. to S.toList
    putStrLn $ "Number of online drives: " ++ show cnt
    putStrLn $ "Online drive ids       : " ++ show online
    putStrLn "-------------------------------------"

--------------------------------------------------------------------------------
network :: ComplexEvent s Input (Event ())
network = onEventM handler .
          snapshot         .
          first appState   . (_OnDriveAdded <|> _OnDriveRemoved <|> _OnStatus)
  where
    _OnDriveAdded = (registerDrive &&& driveAddedOutput) . driveAdded

    _OnDriveRemoved = (unregisterDrive &&& driveRemovedOutput) . driveRemoved

    _OnStatus = (nop &&& statusOutput) . statusAsked

--------------------------------------------------------------------------------
castorProcess :: Process ()
castorProcess = runProcessor_ def network
  where
    def :: DriveAdded .+. DriveRemoved .+. Status .+. Nil
    def = Ask

--------------------------------------------------------------------------------
drives :: (Int, Int)
drives = (1, 3)

main :: IO ()
main = do
    t <- either throwIO return =<<
         createTransport "127.0.0.1" "4000" defaultTCPParameters
    n <- newLocalNode t initRemoteTable

    runProcess n $ do

        cid <- spawnLocal castorProcess

        _ <- spawnLocal $ forever $ do
            send cid Status
            liftIO $ threadDelay (5 * 1000000)

        _ <- spawnLocal $ forever $ do
            d <- liftIO $ randomRIO drives
            send cid (DriveAdded d)
            liftIO $ threadDelay (1 * 1000000)

        _ <- spawnLocal $ forever $ do
            d <- liftIO $ randomRIO drives
            send cid (DriveRemoved d)
            liftIO $ threadDelay (2 * 1000000)

        _ <- liftIO getLine
        return ()
