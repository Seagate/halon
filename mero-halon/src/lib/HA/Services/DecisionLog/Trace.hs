{-# LANGUAGE GADTs #-}
module HA.Services.DecisionLog.Trace
  ( newTracer
  , traceLogs
  ) where

import qualified Data.ByteString.Lazy as B
import Data.Binary
import Control.Distributed.Process
import Data.Functor (void)
import Data.Time (getCurrentTime)
import Text.PrettyPrint.Leijen hiding ((<>),(<$>))
import System.IO
import Network.CEP.Log as CL
import HA.RecoveryCoordinator.Log as Log

import HA.Services.DecisionLog.Types
import HA.Services.DecisionLog.Logger

-- | Create new logger that will dump raw traces.
newTracer :: TraceLogOutput -> Logger
newTracer TraceNull = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop WriteLogger{} = return self
  loop CloseLogger = return ()
newTracer TraceTextDP = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop (WriteLogger x) = say (show $ ppLogs x) >> return self
  loop CloseLogger = return ()
newTracer (TraceProcess p) = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop (WriteLogger x) = usend p x >> return self
  loop CloseLogger = return ()
newTracer (TraceText path) = self where
  self = Logger loop
  loop :: LoggerQuery a -> Process a
  loop (WriteLogger lg) = liftIO $ withFile path AppendMode $ \h -> do
    hPutStrLn h . show =<< getCurrentTime
    hPutDoc h $ ppLogs lg
    hPutStr h "\n"
    return self
  loop CloseLogger = return ()
newTracer (TraceBinary path) = self where
   self = Logger loop
   loop :: LoggerQuery a -> Process a
   loop (WriteLogger lg) = liftIO $ withBinaryFile path AppendMode $ \h -> do
     B.hPut h (encode lg)
     return self
   loop CloseLogger = return () 

-- | Pretty-print a log entry
ppLogs :: CL.Event Log.Event -> Doc
ppLogs evt =
    ppLoc (CL.evt_loc evt) <+> ppEvt (CL.evt_log evt)
  where
    ppLoc CL.Location{..} = encloseSep lbrace rbrace colon
      $ text <$> [loc_rule_name, show loc_sm_id, loc_phase_name]
    ppJump (CL.NormalJump s) = text s
    ppJump (CL.TimeoutJump t s) =
      text "timeout" <+> parens (text $ show t) <+> text s
    ppEvt (CL.PhaseLog CL.PhaseLogInfo{..}) =
      text pl_key <+> hcat [equals, rangle] <+> text pl_value
    ppEvt CL.PhaseEntry = text "ENTER_PHASE"
    ppEvt CL.Stop = text "STOP"
    ppEvt CL.Suspend = text "SUSPEND"
    ppEvt (CL.Continue CL.ContinueInfo{..}) =
      text "CONTINUE" <+> ppJump c_continue_phase
    ppEvt (CL.Switch CL.SwitchInfo{..}) =
      text "SWITCH" <+> ( encloseSep lbracket rbracket comma
                        $ ppJump <$> s_switch_phases)
    ppEvt _ = empty

-- | Helper for default trace storage.
traceLogs :: CL.Event Log.Event -> Process ()
traceLogs msg = void $ writeLogs (newTracer TraceTextDP) msg
