-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Flags where

import qualified Handler.Bootstrap as Bootstrap

import Options.Applicative
    ( (<$>)
    , (<*>)
    , (<>)
    )
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import System.Environment (getProgName)

data Options = Options
    { optTheirAddress :: [String] -- ^ Addresses of halond nodes to control.
    , optOurAddress   :: String
    , optCommand      :: Command
    }
  deriving (Eq)

data Command =
    Bootstrap Bootstrap.BootstrapOptions
  deriving (Eq)

getOptions :: IO Options
getOptions = do
    self <- getProgName
    O.execParser $
      O.withFullDesc self parseOptions "Control nodes (halond instances)."
  where
    parseOptions :: O.Parser Options
    parseOptions = Options
        <$> (O.many . O.strOption $ O.metavar "ADDRESSES" <>
               O.long "address" <>
               O.short 'a' <>
               O.help "Addresses of nodes to control.")
        <*> (O.strOption $ O.metavar "ADDRESS" <>
               O.long "listen" <>
               O.short 'l' <>
               O.value "0.0.0.0:9001" <>
               O.help "Address halonctl binds to; defaults to 0.0.0.0:0.")
        <*> (O.subparser $ O.command "bootstrap" $ Bootstrap <$>
               O.withDesc Bootstrap.parseBootstrap "Bootstrap a node.")
