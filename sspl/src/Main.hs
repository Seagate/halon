-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Generate bindings.

{-# LANGUAGE OverloadedStrings #-}

import qualified SSPL.Schemata.SensorResponse as SensorResponse
import qualified SSPL.Schemata.ActuatorRequest as ActuatorRequest
import qualified SSPL.Schemata.ActuatorResponse as ActuatorResponse

import Data.Aeson.Schema
import Data.Aeson.Schema.CodeGen

import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as T

import Language.Haskell.TH

main :: IO ()
main = let
    schemata = [
        ("SensorResponse", SensorResponse.schema)
      , ("ActuatorRequest", ActuatorRequest.schema)
      , ("ActuatorResponse", ActuatorResponse.schema)
      ]
  in mapM_ (uncurry mkBindings) schemata

mkBindings name schema = let
    graph = M.singleton name schema
  in do
    (code, _) <- runQ $ generateModule
                          ( "SSPL.Bindings." `T.append` name)
                          graph
    T.writeFile ("src/SSPL/Bindings/" ++ (T.unpack name) ++ ".hs")  code
