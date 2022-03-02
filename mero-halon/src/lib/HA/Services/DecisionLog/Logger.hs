{-# LANGUAGE GADTs           #-}
{-# LANGUAGE RankNTypes      #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE ViewPatterns    #-}
-- |
-- Module    : HA.Services.DecisionLog.Logger
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Various 'Logger' specifications used by the decision-log service.
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
  -- * Dump functions.
  , dumpTextToFile
  , dumpTextToHandle
  , dumpTextToDp
  , dumpBinaryToFile
  ) where

import           Control.Distributed.Process
import           Control.Lens hiding (Context, Level)
import           Data.Aeson (ToJSON, FromJSON, encode)
import qualified Data.ByteString.Lazy as B
import           Data.ByteString.Lazy (ByteString)
import           Data.Int
import           Data.List (insert)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import           Data.Time
import           Data.Typeable (Typeable)
import           Data.UUID hiding (null)
import           GHC.Generics
import           HA.RecoveryCoordinator.Log as RC
import           Network.CEP.Log as CEP
import           System.IO
import           Text.PrettyPrint.Leijen hiding ((<$>))

type SmId = Int64

type LogEvent = CEP.CEPLog RC.Event

-- | A log collects consecutive events for a given location, along
--   with any contexts that apply.
data Log = Log Location [LogEvent] [TagContextInfo]
  deriving (Generic, Typeable)

instance ToJSON Log
instance FromJSON Log

-----------------------------------------------------------------------------------------
-- Printers that used to dump raw data to the output.
-----------------------------------------------------------------------------------------

-- | Query to the printer mechanism.
data PrinterQuery a where
  PrintMessage :: Log -> PrinterQuery Printer
  ClosePrinter :: PrinterQuery ()

-- | Tell the 'Printer' to output the given 'Log' with the given
-- context.
printMessage :: Printer -> Log -> Process Printer
printMessage (Printer runPrinter) l = runPrinter $ PrintMessage l

-- | Instruct 'Printer' to close.
closePrinter :: Printer -> Process ()
closePrinter (Printer runPrinter) = runPrinter ClosePrinter

-- | Printer state machine.
newtype Printer = Printer (forall a . PrinterQuery a -> Process a)

-- | Record text messages somewhere.
mkTextPrinter :: (String -> Process ()) -> Process () -> Printer
mkTextPrinter emit close = self where
  self = Printer loop
  loop :: PrinterQuery a -> Process a
  loop (PrintMessage msg) = do
    now <- liftIO $ getCurrentTime
    emit $ formatTimeLog now
    emit $ displayS (renderPretty 0.4 180 (ppLog msg)) ""
    return self
  loop ClosePrinter = close

-- | A pretty printer for log messages
ppLog :: Log -> Doc
ppLog (Log loc evts ctts) =
    ppLoc loc <$$> indent 4
      ( (vsep . catMaybes $ ppEvt <$> evts)
      <$$> text "----------"
      <$$> (let docs = ppCtt <$> ctts
            -- Ensure that contexts section ends with a blank line.
            in vsep $ if null docs then [] else docs ++ [empty])
      )
  where
    ppLoc (Location r s p) =
      text r <> char '/' <> text p <+> parens (text . show $ s)
    ppEvt PhaseEntry = Nothing  -- Logging PhaseEntry is pointless: we wouldn't
                                -- be able to log anything without entering
                                -- some phase first.
    ppEvt (Fork finfo) = Just . text $ "Fork: " ++ show (f_buffer_type finfo)
                                     ++ " " ++ show (f_sm_child_id finfo)
    ppEvt (Continue info) = Just . text $ "Continue: " ++ show (c_continue_phase info)
    ppEvt (Switch info) = Just $ text "Switch:" <+> semiBraces (text . show <$> s_switch_phases info)
    ppEvt Stop = Just langle
    ppEvt Suspend = Just $ char '~'
    ppEvt (Restart _) = Just $ char '^'
    ppEvt (StateLog (StateLogInfo env)) = Just $ ppEnv env
    ppEvt (ApplicationLog (ApplicationLogInfo value)) = Just $ char '§' <> ppAL value

    ppAL (EvtInContexts ctxs' evt) = ppALC evt <+> ppCtxs ctxs'
    ppAL _ = empty

    ppALC (CE_SystemEvent (StateChange info)) = text "State Change:"
      <+> text (lsc_entity info) <> colon
      <+> text (lsc_oldState info) <+> text "==>" <+> text (lsc_newState info)

    ppALC (CE_SystemEvent (ActionCalled info env)) = text "Invoked:"
      <+> text info
      <+> ppEnv env

    ppALC (CE_SystemEvent (RCStarted node)) = text "RC Started on node"
      <+> text (show node)

    ppALC (CE_SystemEvent (Todo uid)) = text "TODO:" <+> text (show uid)
    ppALC (CE_SystemEvent (Done uid)) = text "DONE:" <+> text (show uid)

    ppALC (CE_UserEvent lvl _ ue) = text (show lvl) <+> ppUE ue
      where
        ppUE (Env env) = ppEnv env
        ppUE (Message str) = text str

    ppALC _ = empty

    ppCtt (TagContextInfo ctx dat _) = case ctx of
        Local _ -> text (show ctx) <> line <> indent 4 (ppDat dat)
        _       -> ppDat dat
      where
        ppDat (TagString str) = text str
        ppDat (TagEnv env) = ppEnv env
        ppDat (TagScope scopes) = text "Scopes:" <+> sep (text . show <$> scopes)

    ppCtxs ctx = tupled $ text <$> catMaybes (pullLocalCtx <$> ctx)
      where
        pullLocalCtx (Local uid) = Just $ show uid
        pullLocalCtx _ = Nothing

    ppEnv env = sep
      $   (\(a,b) -> text a <+> equals <> rangle <+> text b)
      <$> Map.toList env

-- | Create logger that put data to the binary file.
mkBinaryPrinter :: (ByteString -> Process ()) -> Process () -> Printer
mkBinaryPrinter emit close = self where
  self = Printer loop
  loop :: PrinterQuery a -> Process a
  loop (PrintMessage lg) = do
    emit $ encode lg
    return self
  loop ClosePrinter = close

-- | Append the given 'String' to the given file.
dumpTextToFile :: FilePath -> String -> Process ()
dumpTextToFile fp s = liftIO $ withFile fp AppendMode $ \h -> hPutStrLn h s

-- | Write the given 'String' to the given 'Handle'.
dumpTextToHandle :: Handle -> String -> Process ()
dumpTextToHandle h s = liftIO $ hPutStrLn h s

-- | Append the given 'ByteString' to the given file.
dumpBinaryToFile :: FilePath -> ByteString -> Process ()
dumpBinaryToFile fp s = liftIO $ withFile fp AppendMode $ \h -> B.hPut h s

-- | Send the given 'String' to the local 'Process' (i.e. 'say').
dumpTextToDp :: String -> Process ()
dumpTextToDp = say

formatTimeLog :: UTCTime -> String
formatTimeLog = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S%Q"
-----------------------------------------------------------------------------------------
-- Loggers
-----------------------------------------------------------------------------------------

-- | 'Logger' commands
data LoggerQuery a where
  WriteLogger :: CEP.Event RC.Event -> LoggerQuery Logger
  CloseLogger :: LoggerQuery ()

-- | A 'Logger' perform actions based on provided 'LoggerQuery'.
newtype Logger = Logger (forall a . LoggerQuery a -> Process a)

-- | Instruct logger to write out the 'CEP.Event'.
writeLogs :: Logger -> CEP.Event RC.Event -> Process Logger
writeLogs logger msg | isWrapper = return logger
  where
    isWrapper = let n = CEP.loc_phase_name $ CEP.evt_loc msg
                in n `elem` ["wrapper_init", "wrapper_clear", "wrapper_end"]
writeLogs (Logger runLogger) msg =  runLogger $ WriteLogger msg

-- | Instruct 'Logger' to close.
closeLogger :: Logger -> Process ()
closeLogger (Logger runLogger) = runLogger CloseLogger

--------------------------------------------------------------------------------
-- Basic logger
--------------------------------------------------------------------------------

-- | State used by 'Logger'.
data LoggerState = LS
  { _localContexts      :: !(Map SmId [UUID])
    -- ^ Local contexts opened in SM
  , _rulesScopes        :: !(Map String [TagContextInfo])
    -- ^ Scopes associated with a rule.
  , _smScopes           :: !(Map SmId [TagContextInfo])
    -- ^ Scopes associated with a state machine.
  , _currentPhaseScopes :: !(Map SmId [TagContextInfo])
    -- ^ Scopes associated with a current phase.
  , _contextScopes      :: !(Map UUID [TagContextInfo])
    -- ^ Scopes associated with a local scope.
  , _phaseEvents        :: !(Maybe (Location, [LogEvent]))
    -- ^ Events associated with the current location.
  }

makeLenses ''LoggerState

-- | Initial 'LoggerState'.
initState :: LoggerState
initState = LS Map.empty Map.empty Map.empty Map.empty Map.empty Nothing

insertToList :: (Ord k, Ord v) => k -> v -> Map k [v] -> Map k [v]
insertToList k v = Map.alter (maybe (Just [v]) (Just . insert v)) k

-- | Given a 'Printer', create a 'Logger'.
mkLogger :: Printer -> Logger
mkLogger printer0 = mk printer0 initState where
  mk p st = Logger $ go p st
  go :: Printer -> LoggerState -> LoggerQuery a -> Process a
  go p st (WriteLogger msg) = feedLog p st msg
  go p _  CloseLogger = closePrinter p
  feedLog :: Printer -> LoggerState -> CEP.Event RC.Event -> Process Logger
  feedLog p !st evt@(Event loc msg) = case msg of
    Fork  _    -> mkRec evt False p st id
    Switch _   -> mkRec evt True p st $ forgetCurrentPhase (loc_sm_id loc)
    Continue _ -> mkRec evt True p st $ forgetCurrentPhase (loc_sm_id loc)
    Stop       -> mkRec evt True p st $ forgetSM (loc_sm_id loc)
    Suspend    -> mkRec evt True p st $ forgetCurrentPhase (loc_sm_id loc)
    Restart _  -> mkRec evt True p st $ forgetSM (loc_sm_id loc)
    PhaseEntry -> mkRec evt False p st $ forgetCurrentPhase (loc_sm_id loc)
    StateLog _ -> mkRec evt False p st id
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
            ctx = tc_context info
            f = \x -> case ctx of
                        Rule    -> rulesScopes %~ insertToList rname x
                        Phase   -> currentPhaseScopes %~ insertToList smId x
                        SM      -> smScopes %~ insertToList smId x
                        Local u -> contextScopes %~ insertToList u x
        return $! mk p (st & f info)
      EvtInContexts _ event -> do
         case event of
           CE_SystemEvent se -> do
            let st' = case se of
                        RCStarted{} -> initState
                        _ -> st
            mkRec evt False p st' id
           CE_UserEvent _ _ _ -> mkRec evt False p st id

  -- Record an event for the current Location, and emit events for either:
  -- - Current location if 'emit' is set.
  -- - Old location if new location does not match the state.
  recordEvent :: CEP.Event RC.Event
              -> Bool
              -> Printer
              -> LoggerState
              -> Process (Printer, LoggerState)
  recordEvent (Event loc evt) emit p st = (\(a,b) -> (,b) <$> a) $
    case (st ^. phaseEvents) of
      (Just (oldLoc, events)) | loc == oldLoc -> let
          -- Same location
          logMsg = Log loc (reverse events') $ getCurrentTags st loc
          events' = evt : events
          (p', st') =
            if emit
            then (printMessage p logMsg, st & (phaseEvents .~ Nothing))
            else (return p, st & (phaseEvents .~ Just (loc, events')))
        in (p', st')
      Just (oldLoc, events) -> let
          -- We have a location, but it's different to the old one...
          oldLogMsg = Log oldLoc (reverse events) $ getCurrentTags st oldLoc
          (p', st') =
            if emit
            then let
                newLogMsg = Log loc [evt] $ getCurrentTags st loc
              in  ( printMessage p oldLogMsg >>= flip printMessage newLogMsg
                  , st & phaseEvents .~ Nothing
                  )
            else  ( printMessage p oldLogMsg
                  , st & (phaseEvents .~ Just (loc, [evt]))
                  )
        in (p', st')
      Nothing -> if emit
        then let
            newLogMsg = Log loc [evt] $ getCurrentTags st loc
          in ( printMessage p newLogMsg, st )
        else
          (return p, st & phaseEvents .~ Just (loc, [evt]))

  -- Make a logger recording this event, and taking the specified action
  -- after doing so.
  mkRec :: CEP.Event RC.Event -> Bool -> Printer -> LoggerState
        -> (LoggerState -> LoggerState) -> Process Logger
  mkRec evt emit p st act = do
    (p', st') <- recordEvent evt emit p st
    return $ Logger $ go p' (act st')

  -- We have moved from the phase to another, no need to remember the context.
  forgetCurrentPhase :: SmId -> LoggerState -> LoggerState
  forgetCurrentPhase smId st = st & currentPhaseScopes %~ Map.delete smId
  -- Remove state machine from the state, as it's finished execution.
  forgetSM :: SmId -> LoggerState -> LoggerState
  forgetSM smId st = st & (localContexts %~ Map.delete smId)
                        . (smScopes      %~ Map.delete smId)
                        . (currentPhaseScopes %~ Map.delete smId)
  getTagsByContext :: LoggerState -> Location -> Context -> [TagContextInfo]
  getTagsByContext st (loc_rule_name -> rname) Rule =
    fromMaybe [] . Map.lookup rname $ st ^. rulesScopes
  getTagsByContext st (loc_sm_id -> smId) Phase =
    fromMaybe [] . Map.lookup smId $ st ^. currentPhaseScopes
  getTagsByContext st (loc_sm_id -> smId) SM =
    fromMaybe [] . Map.lookup smId $ st ^. smScopes
  getTagsByContext st _ (Local u) =
    fromMaybe [] . Map.lookup u $ st ^. contextScopes
  getCurrentTags :: LoggerState -> Location -> [TagContextInfo]
  getCurrentTags st loc@(loc_sm_id -> smId) =
    let a  = getTagsByContext st loc Rule
        b  = getTagsByContext st loc Phase
        c  = getTagsByContext st loc SM
        ds = fmap (getTagsByContext st loc . Local)
                $ fromMaybe [] . Map.lookup smId $ st ^. localContexts
    in concat (a:b:c:ds)
