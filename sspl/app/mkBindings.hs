-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Generate bindings.

{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

import qualified SSPL.Schemata.SensorRequest as SensorRequest
import qualified SSPL.Schemata.SensorResponse as SensorResponse
import qualified SSPL.Schemata.ActuatorRequest as ActuatorRequest
import qualified SSPL.Schemata.ActuatorResponse as ActuatorResponse
import qualified SSPL.Schemata.CommandRequest as CommandRequest
import qualified SSPL.Schemata.CommandResponse as CommandResponse

import Data.Aeson.Schema
import Data.Aeson.Schema.CodeGen
import Data.Aeson.Schema.CodeGenM (Options(..), defaultOptions)

import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as T

import Language.Haskell.TH

import Data.Binary
import Data.Hashable
import Data.Typeable
import GHC.Generics


main :: IO ()
main = let
    schemata = [
        ("SensorRequest", SensorRequest.schema)
      , ("SensorResponse", SensorResponse.schema)
      , ("ActuatorRequest", ActuatorRequest.schema)
      , ("ActuatorResponse", ActuatorResponse.schema)
      , ("CommandRequest", CommandRequest.schema)
      , ("CommandResponse", CommandResponse.schema)
      ]
  in mapM_ (uncurry mkBindings) schemata

mkBindings name schema = do
  let graph = M.singleton name schema
      appV f v = f defaultOptions ++ v
  (code, _) <- runQ $ generateModule
               ( "SSPL.Bindings." `T.append` name)
               graph
               (defaultOptions { _extraModules = appV _extraModules ["SSPL.Bindings.Instances ()"]
                               , _derivingTypeclasses =
                                   appV _derivingTypeclasses [''Generic, ''Typeable]
                               , _languageExtensions = [ "DeriveDataTypeable"
                                                       , "DeriveGeneric"
                                                       , "StandaloneDeriving" ]
                               , _extraInstances =
                                     \n -> [ instanceD (cxt []) (conT ''Binary `appT` conT n) []
                                           , instanceD (cxt []) (conT ''Hashable `appT` conT n) []
                                           ]
                               , _replaceModules = M.fromList
                                  [ ("Data.Hashable.Class", "Data.Hashable")
                                  , ("Data.Text.Show", "Data.Text") ]
                                  `M.union`
                                  _replaceModules defaultOptions
                               })
  T.writeFile ("src/SSPL/Bindings/" ++ (T.unpack name) ++ ".hs")  code
