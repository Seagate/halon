-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Common helpers/structures used throughout halon-st
module HA.ST.Common where

data HASTTest = HASTTest { _st_name :: String
                           -- ^ ST name
                         , _st_action :: IO (Maybe String)
                           -- ^ Test runner that can fail with error
                           -- message
                         }

instance Show HASTTest where
  show = _st_name
