{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TemplateHaskell #-}
module HA.Services.DecisionLog.Logger
  ( -- * Logger
    Logger(..)
  , LoggerQuery(..)
  , writeLogs
  , closeLogger
  , mkLogger
    -- * Printer
  , Printer
  , printMessage
  , closePrinter
  , mkTextPrinter
  , mkBinaryPrinter
  , LogRecord(..)
  -- * Dump functions.
  , dumpTextToFile
  , dumpTextToHandle
  , dumpTextToDp
  , dumpBinaryToFile
  ) where

import qualified Data.ByteString.Lazy as B
import Data.ByteString.Lazy (ByteString)
import Data.SafeCopy
import Data.Serialize
import GHC.Generics

import Control.Distributed.Process

import HA.RecoveryCoordinator.Log

import System.IO

-- Logger
import Data.UUID
import Data.Int
import Data.Maybe
import Data.List (insert)
import Data.Map (Map)
import qualified Data.Map as Map
import HA.RecoveryCoordinator.Log as RC
import Network.CEP.Log as CEP
import Control.Lens hiding (Context, Level)

type SmId = Int64
data RCSrc = RCSrc { _rcSrcRule :: String, _rcSrcPhase :: String } deriving (Show)

data Log = Log RCSrc LogData deriving (Show)

data LogData = LogSystem SystemEvent
             | LogMessage Level String (Maybe SourceLoc)
             | LogEnv Level Environment (Maybe SourceLoc)
             deriving (Show)
-----------------------------------------------------------------------------------------
-- Printers that used to dump raw data to the output.
-----------------------------------------------------------------------------------------

-- | Query to the printer mechanism.
data PrinterQuery a where
  PrintMessage :: Log -> [(TagContent, Maybe String)] -> PrinterQuery Printer
  ClosePrinter :: PrinterQuery ()

printMessage :: Printer -> Log -> [(TagContent, Maybe String)] -> Process Printer
printMessage (Printer runPrinter) l ctx = runPrinter $ PrintMessage l ctx

closePrinter :: Printer -> Process ()
closePrinter (Printer runPrinter) = runPrinter ClosePrinter
  
-- | Printer state machine.
newtype Printer = Printer (forall a . PrinterQuery a -> Process a)

-- | Record text messages somewhere.
mkTextPrinter :: (String -> Process ()) -> Process () -> Printer
mkTextPrinter emit close = self where
 self = Printer loop
 loop :: PrinterQuery a -> Process a
 loop (PrintMessage (Log (RCSrc r p) ls) scopes) = do
  emit . unlines $
    [ "======================================"
    , "Rule/phase: " ++ r ++ "/" ++ p
    , show ls
    , "Context: "
    ] ++ map show scopes
  return self
 loop ClosePrinter = close

-- | Record to be stored in logs, it's completely uncompressed.
data LogRecord = LogRecord Log [(TagContent, Maybe String)] deriving (Show, Generic)
deriveSafeCopy 0 'base ''LogRecord

-- | Create logger that put data to the binary file.
mkBinaryPrinter :: (ByteString -> Process ()) -> Process () -> Printer
mkBinaryPrinter emit close = self where
  self = Printer loop
  loop :: PrinterQuery a -> Process a
  loop (PrintMessage lg scopes) = do
    emit $ runPutLazy (safePut (LogRecord lg scopes))
    return self
  loop ClosePrinter = close

dumpTextToFile :: FilePath -> String -> Process ()
dumpTextToFile fp s = liftIO $ withFile fp AppendMode $ \h -> hPutStrLn h s

dumpTextToHandle :: Handle -> String -> Process ()
dumpTextToHandle h s = liftIO $ hPutStrLn h s

dumpBinaryToFile :: FilePath -> ByteString -> Process ()
dumpBinaryToFile fp s = liftIO $ withFile fp AppendMode $ \h -> B.hPut h s

dumpTextToDp :: String -> Process ()
dumpTextToDp = say

-----------------------------------------------------------------------------------------
-- Loggers
-----------------------------------------------------------------------------------------

data LoggerQuery a where
  WriteLogger :: CEP.Event RC.Event -> LoggerQuery Logger
  CloseLogger :: LoggerQuery ()

newtype Logger = Logger (forall a . LoggerQuery a -> Process a)

writeLogs :: Logger -> CEP.Event RC.Event -> Process Logger
writeLogs (Logger runLogger) msg =  runLogger $ WriteLogger msg

closeLogger :: Logger -> Process ()
closeLogger (Logger runLogger) = runLogger CloseLogger

----------------------------------------------------------------------------------------
-- Basic logger
----------------------------------------------------------------------------------------

data LoggerState = LS
  { _localContexts      :: !(Map SmId [UUID])
    -- ^ Local contexts opened in SM
  , _rulesScopes        :: !(Map String [(TagContent, Maybe String)])
    -- ^ Scopes associated with a rule.
  , _smScopes           :: !(Map SmId [(TagContent, Maybe String)])
    -- ^ Scopes associated with a state machine.
  , _currentPhaseScopes :: !(Map SmId [(TagContent, Maybe String)])
    -- ^ Scopes associated with a current phase.
  , _contextScopes      :: !(Map UUID [(TagContent, Maybe String)])
    -- ^ Scopes associated with a local scope.
  } deriving (Show)

makeLenses ''LoggerState

initState :: LoggerState
initState = LS Map.empty Map.empty Map.empty Map.empty Map.empty

insertToList :: (Ord k, Ord v) => k -> v -> Map k [v] -> Map k [v]
insertToList k v = Map.alter (maybe (Just [v]) (Just .insert v)) k

mkLogger :: Printer -> Logger
mkLogger printer0 = mk printer0 initState where
  mk p st = Logger $ go p st
  go :: Printer -> LoggerState -> LoggerQuery a -> Process a
  go p st (WriteLogger msg) = feedLog p st msg
  go p _  CloseLogger = closePrinter p
  feedLog :: Printer -> LoggerState -> CEP.Event RC.Event -> Process Logger
  feedLog p !st (Event loc msg) = case msg of
    Fork  _    -> return $ mk p st
    Switch _   -> return $ mk p $ forgetCurrentPhase st (loc_sm_id loc)
    Continue _ -> return $ mk p $ forgetCurrentPhase st (loc_sm_id loc)
    Stop       -> return $ mk p $ forgetSM st (loc_sm_id loc)
    Suspend    -> return $ mk p $ forgetCurrentPhase st (loc_sm_id loc)
    Restart _  -> return $ mk p $ forgetSM st (loc_sm_id loc)
    PhaseEntry -> return $ mk p $ forgetCurrentPhase st (loc_sm_id loc)
    PhaseLog info -> do
      let rloc = RCSrc (loc_rule_name loc) (loc_phase_name loc)
          m    = Log rloc (LogEnv DEBUG  (Map.singleton (pl_key info) (pl_value info)) Nothing)
          scopes = getCurrentTags st loc
      p' <- printMessage p m scopes
      return $! mk p' st
    StateLog info -> do
      let rloc = RCSrc (loc_rule_name loc) (loc_phase_name loc)
          m    = Log rloc (LogEnv DEBUG (sl_state info) Nothing)
          scopes = getCurrentTags st loc
      p' <- printMessage p m scopes
      return $! mk p' st
    ApplicationLog (ApplicationLogInfo app) -> case app of
      BeginLocalContext uuid ->
         return $! mk p $! st & localContexts %~ insertToList (loc_sm_id loc) uuid
      EndLocalContext uuid   -> do
         let smId = loc_sm_id loc
         return $! mk p $! st & (localContexts %~ Map.alter (maybe (Just [uuid]) (Just . filter (/= uuid))) smId)
                              . (contextScopes %~ Map.delete uuid)
      TagContext info -> do 
        let rname = loc_rule_name loc
            smId  = loc_sm_id loc
            tag   = tc_data info
            comment = tc_msg info
            ctx = tc_context info
            f = \x -> case ctx of
                        Rule    -> rulesScopes %~ insertToList rname x
                        Phase   -> currentPhaseScopes %~ insertToList smId x
                        SM      -> smScopes %~ insertToList smId x 
                        Local u -> contextScopes %~ insertToList u x
        return $! mk p (st & f (tag, comment))
      EvtInContexts ctxs event -> do
         let rloc = RCSrc (loc_rule_name loc) (loc_phase_name loc)
             scopes = concat $ getTagsByContext st loc <$> ctxs
         case event of
           CE_SystemEvent se -> do
            let st' = case se of
                        RCStarted{} -> initState
                        _ -> st
            p' <- printMessage p (Log rloc (LogSystem se)) scopes
            return $! mk p' st'
           CE_UserEvent lvl msloc ue ->
            case ue of
              Env e -> do 
                p' <- printMessage p (Log rloc (LogEnv lvl e msloc)) scopes
                return $! mk p' st
              Message s -> do
                p' <- printMessage p (Log rloc (LogMessage lvl s msloc)) scopes
                return $! mk p' st

  -- We have moved from the phase to another, no need to remember the context.
  forgetCurrentPhase :: LoggerState -> SmId -> LoggerState
  forgetCurrentPhase st smId = st & currentPhaseScopes %~ Map.delete smId
  -- Remove state machine from the state, as it's finished execution.
  forgetSM :: LoggerState -> SmId -> LoggerState
  forgetSM st smId = st & (localContexts %~ Map.delete smId)
                        . (smScopes      %~ Map.delete smId)
                        . (currentPhaseScopes %~ Map.delete smId)
  getTagsByContext :: LoggerState -> Location -> Context -> [(TagContent,Maybe String)]
  getTagsByContext st (loc_rule_name -> rname) Rule =
    fromMaybe [] . Map.lookup rname $ st ^. rulesScopes
  getTagsByContext st (loc_sm_id -> smId) Phase = 
    fromMaybe [] . Map.lookup smId $ st ^. currentPhaseScopes
  getTagsByContext st (loc_sm_id -> smId) SM =
    fromMaybe [] . Map.lookup smId $ st ^. smScopes
  getTagsByContext st _ (Local u) =
    fromMaybe [] . Map.lookup u $ st ^. contextScopes
  getCurrentTags :: LoggerState -> Location -> [(TagContent, Maybe String)]
  getCurrentTags st loc@(loc_sm_id -> smId) =
    let a  = getTagsByContext st loc Rule
        b  = getTagsByContext st loc Phase
        c  = getTagsByContext st loc SM
        ds = fmap (getTagsByContext st loc . Local)
                $ fromMaybe [] . Map.lookup smId $ st ^. localContexts
    in concat (a:b:c:ds)


deriveSafeCopy 0 'base ''RCSrc
deriveSafeCopy 0 'base ''LogData
deriveSafeCopy 0 'base ''Log

