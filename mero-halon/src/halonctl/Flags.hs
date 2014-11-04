-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Flags where

import Options.Applicative
    ( (<$>)
    , (<*>)
    , (<>)
    )
import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import qualified Handler.Bootstrap as Bootstrap

data Options = Options
    { optTheirAddress :: [String] -- ^ Addresses of halond nodes to control.
    , optOurAddress   :: String
    , optCommand      :: Command
    }
  deriving (Eq)

data Command =
    Bootstrap Bootstrap.BootstrapOptions
  deriving (Eq)

self :: String
self = "halonctl"

getOptions :: IO Options
getOptions =
    O.execParser $
      O.withFullDesc self parseOptions
        "Control Cloud Haskell nodes run by halond"

parseOptions :: O.Parser Options
parseOptions =
    Options <$>
        parseTheirAddress
    <*> parseOurAddress
    <*> parseCommand

parseTheirAddress :: O.Parser [String]
parseTheirAddress =
    O.many . O.strOption $
         O.metavar "ADDRESSES"
      <> O.long "address"
      <> O.short 'a'
      <> O.help "Addresses of nodes to control; default 127.0.0.1:9000"

parseOurAddress :: O.Parser String
parseOurAddress =
    O.strOption $
         O.metavar "LISTEN"
      <> O.long "listen"
      <> O.short 'l'
      <> O.value "127.0.0.1:9001"
      <> O.help "Address halonctl binds to; default 127.0.0.1:9001"

parseCommand :: O.Parser Command
parseCommand =
  O.subparser $
    O.command "bootstrap"
      (Bootstrap <$> O.withDesc Bootstrap.parseBootstrap "Bootstrap a node")
