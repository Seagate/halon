-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schemata.CommandRequest where

import Data.Aeson.Schema

schema = [schemaQQ|
{
  "$schema":"http://json-schema.org/draft-03/schema#",
  "type":"object",
  "properties": {
    "serviceRequest" : {
      "type" : "object",
      "properties" : {
        "serviceName" : {
          "required" : true,
          "type" : "string",
          "description" : "Name of the service to control."
        },
        "command" : {
          "required" : true,
          "enum" : ["start", "stop", "restart", "enable", "disable", "status"]
        },
        "nodes" : {
          "required" : false,
          "type" : "string",
          "description" : "Regex on node FQDNs. If not specified, applies to all nodes."
        }
      }
    }
  }
}
  |]
