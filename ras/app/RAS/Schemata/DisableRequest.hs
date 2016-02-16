-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings. Describes messages
-- sent from halon to RAS, returning the current failure set.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module RAS.Schemata.DisableRequest where

import Data.Aeson.Schema

schema = [schemaQQ|
{
  "$schema": "http://json-schema.org/draft-03/schema#",
  "id": "http://json-schema.org/draft-03/schema#",
  "type": "object",
  "properties": {
    "message": {
      "type": "object",
      "required": true,
      "properties": {
        "ras_message_header": {
          "message_uuid": {
            "description": "Universally Unique ID of message",
            "type": "string",
            "required": true
          },
          "session_uuid": {
            "description": "Universally Unique ID of session",
            "type": "string",
            "required": true
          },
          "send_time": {
            "description": "The time the message was sent",
            "type": "string",
            "required": true
          }
        },
        "failure_set_query_response": {
          "description": "Reply to failure set query",
          "type": "object",
          "required": true,
          "properties": {
            "device": {
              "description": "Device we want to disable",
              "type": "array",
              "required": true
            },
            "disable status": {
              "description": "Disabling or enabling",
              "type": { "enum": [ "disable", "enable" ] },
              "required": true
            }
          }
        }
      }
    }
  }
}

|]
