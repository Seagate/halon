-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.

module Flags (Mode(..), Config(..), parseArgs) where

import System.Console.GetOpt
import HA.Network.Address
import Control.Exception (throw)

data Mode = Help | Version | Run

data Config = Config
    { mode :: Mode
    , localEndpoint :: Address
    , localLookup :: Address
    , update :: Bool
    }

defaultConfig :: Config
defaultConfig =
    Config { mode = Run
           , localLookup = error "No lookup address given."
           , localEndpoint = error "No address to listen on given."
           , update = False
           }

options :: [OptDescr (Config -> Config)]
options =
    [ Option [] ["help"] (NoArg $ \c -> c{mode=Help})         "This help message."
    , Option [] ["version"] (NoArg $ \c -> c{mode=Version})   "Display version information."
    , Option ['a'] ["agentlookup"] (ReqArg (\s c -> c{ localLookup =
            maybe (error "Invalid address") id (parseAddress s) }) "ADDRESS")
                 "Address of lookup service."
    , Option ['l'] ["listen"] (ReqArg (\s c -> c{ localEndpoint =
            maybe (error "Invalid address") id (parseAddress s) }) "ADDRESS")
                 "Address to listen on."
    , Option ['u'] ["update"] (NoArg (\c -> c { update = True }))
                 "Update the tracking station membership rather than starting a new tracking station."
    ]

parseArgs :: [String] -> Config
parseArgs argv =
    case getOpt Permute options argv of
      (opts,[],[]) -> foldr (.) id opts defaultConfig
      (_,_,errs) -> throw $ userError $ concat errs ++ usageInfo header options
  where header = "Usage: halon-station [OPTION...]"
