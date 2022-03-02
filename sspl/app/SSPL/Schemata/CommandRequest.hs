-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schemata.CommandRequest where

import Data.Aeson.Schema

schema = [schemaQQ|
{
  "$schema":"http://json-schema.org/draft-03/schema#",
  "type": "object",
  "properties": {
    "username": {
      "description": "Username who generated message",
      "type": "string",
      "required": true
    },
    "signature": {
      "description": "Authentication signature of message",
      "type": "string",
      "required": true
    },
    "time": {
      "description": "The time the signature was generated",
      "type": "string",
      "required": true
    },
    "expires": {
      "description": "The number of secs the signature remains valid after being generated",
      "type": "integer",
      "required": false
    },
    "message": {
      "type":"object",
      "required" : true,
      "properties": {
        "messageId" : {
          "required" : false,
          "type" : "string",
          "description": "Used to identify a response if a response is required."
        },
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
        },
        "statusRequest" : {
          "type": "object",
          "properties" : {
            "entityType" : {
              "required" : true,
              "enum" : ["cluster", "node"],
              "description" : "Type of entity to query the status of."
            },
            "entityFilter" : {
              "required" : false,
              "type" : "string",
              "description" : "Filter on entities to query. Interpretation is dependent on entity type. If not specified, applies to all entities of the given type."
            }
          }
        },
        "nodeStatusChangeRequest" : {
          "type": "object",
          "properties" : {
            "command" : {
              "required" : true,
              "enum" : ["enable", "disable", "poweron", "poweroff"]
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
  }
}
  |]
