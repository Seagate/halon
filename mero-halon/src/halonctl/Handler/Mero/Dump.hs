{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE StrictData #-}
-- |
-- Module    : Handler.Mero.Dump
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Dump
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process hiding (bracket_)
import           Control.Monad (void)
import qualified Data.ByteString as BS
import           Data.Monoid ((<>))
import           HA.EventQueue (promulgateEQ)
import           HA.Resources.Mero (SyncToConfd(..), SyncDumpToBSReply(..))
import qualified Options.Applicative as Opt
import           System.Exit (exitFailure)

newtype Options = Options FilePath
  deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options <$>
  Opt.strOption
    ( Opt.long "filename"
    <> Opt.short 'f'
    <> Opt.help "File to dump confd database to."
    <> Opt.metavar "FILENAME"
    )

run :: [NodeId] -> Options -> Process ()
run eqnids (Options fn) = do
  self <- getSelfPid
  promulgateEQ eqnids (SyncDumpToBS self) >>= flip withMonitor wait
  expect >>= \case
    SyncDumpToBSReply (Left err) -> do
      say $ "Dumping conf to " ++ fn ++ " failed with " ++ err
      liftIO exitFailure
    SyncDumpToBSReply (Right bs) -> do
      liftIO $ BS.writeFile fn bs
      say $ "Dumped conf in RG to this file " ++ fn
  where
    wait = void (expect :: Process ProcessMonitorNotification)
