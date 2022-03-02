{-# LANGUAGE StrictData   #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Module    : Handler.Mero.Update
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
module Handler.Mero.Update
  ( Options(..)
  , parser
  , run
  ) where

import           Control.Distributed.Process
import           Data.Monoid ((<>))
import           HA.RecoveryCoordinator.Mero.Events
import           Handler.Mero.Helpers
import           Mero.ConfC (Fid, strToFid)
import qualified Options.Applicative as Opt

newtype Options = Options [(Fid, String)]
  deriving (Eq, Show)

parser :: Opt.Parser Options
parser = Options <$>
  Opt.many (Opt.option (Opt.eitherReader updateReader)
    (  Opt.help "List of updates to send to halon. Format: <fid>@<conf state>"
    <> Opt.long "set"
    <> Opt.metavar "NOTE"
    ))
  where
   updateReader :: String -> Either String (Fid, String)
   updateReader (break (=='@') -> (fid', '@':state)) = case strToFid fid' of
     Nothing -> Left $ "Couldn't parse fid: " ++ show fid'
     Just fid -> Right $ (fid, state)
   updateReader s = Left $ "Could not parse " ++ s

run :: [NodeId] -> Options -> Process ()
run nids (Options objs) =
  clusterCommand nids Nothing (ForceObjectStateUpdateRequest objs) (say . show)
