-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.

module Flags (Config(..), Mode(..), helpString, parseArgs) where

import System.Console.GetOpt
import Control.Exception (throw)

data Mode = Run | Help | Version

data Config = Config
    { mode :: Mode
    , configFile :: Maybe FilePath
    , localEndpoint :: String
    }

header :: String
header = "Usage: halond [OPTION...]"

defaultConfig :: Config
defaultConfig = Config
    { mode = Run
    , configFile = Nothing
    , localEndpoint = error "No address to listen on given."
    }

options :: [OptDescr (Config -> Config)]
options =
    [ Option [] ["help"] (NoArg $ \c -> c{ mode = Help })
                 "This help message."
    , Option ['v'] ["version"] (NoArg $ \c -> c{ mode = Version })
                 "Display version information."
    , Option ['c'] ["config"] (ReqArg (\fp c -> c{ configFile = Just fp }) "FILE")
                 "Configuration file."
    , Option ['l'] ["listen"] (ReqArg (\s c -> c{ localEndpoint = s }) "ADDRESS")
                 "Address to listen on."
    ]

parseArgs :: [String] -> Config
parseArgs argv =
  case getOpt Permute options argv of
    (setOpts,[],[]) -> foldr (.) id setOpts defaultConfig
    (_,_,errs) -> throw $ userError $ concat errs ++ usageInfo header options

helpString :: String
helpString = usageInfo header options
