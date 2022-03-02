-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schemata.CommandResponse where

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
        "responseId" : {
          "required" : false,
          "type" : "string",
          "description": "Identity of the message this is sent in response to."
        },
        "statusResponse" : {
          "type": "array",
          "items" : {
            "type" : "object",
            "properties" : {
              "entityId" : {
                "required" : true,
                "type" : "string",
                "description" : "Entity identifier. Depends on entity type."
              },
              "status" : {
                "required" : true,
                "type" : "string",
                "description" : "Entity status."
              }
            }
          },
          "uniqueItems" : true
        }
      }
    }
  }
}
|]
