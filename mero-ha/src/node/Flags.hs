-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Flags (Config(..), parseArgs) where

import HA.Network.Address
import System.Console.GetOpt
import Control.Exception (throw)


data Mode = Run | Help | Version

data Config = Config
    { mode :: Mode
    , configFile :: Maybe FilePath
    , localEndpoint :: Address
    , localLookup :: Address
    }

defaultConfig :: Config
defaultConfig =
    Config { mode = Run
           , configFile = Nothing
           , localEndpoint = error "No address to listen on given." 
           , localLookup = error "No lookup address given."}

options :: [OptDescr (Config -> Config)]
options =
    [ Option [] ["help"] (NoArg $ \c -> c{ mode = Help })
                 "This help message."
    , Option [] ["version"] (NoArg $ \c -> c{ mode = Version })
                 "Display version information."
    , Option ['c'] ["config"] (ReqArg (\fp c -> c{ configFile = Just fp }) "FILE")
                 "Configuration file."
    , Option ['a'] ["agentlookup"] (ReqArg (\s c -> c{ localLookup = 
            maybe (error "Invalid address") id (parseAddress s) }) "ADDRESS")
                 "Address of lookup service."
    , Option ['l'] ["listen"] (ReqArg (\s c -> c{ localEndpoint = 
            maybe (error "Invalid address") id (parseAddress s) }) "ADDRESS")
                 "Address to listen on." ]

parseArgs :: [String] -> Config
parseArgs argv =
    case getOpt Permute options argv of
      (setOpts,[],[]) -> foldr (.) id setOpts defaultConfig
      (_,_,errs) -> throw $ userError $ concat errs ++ usageInfo header options
  where header = "Usage: ha-node-agent [OPTION...]"
