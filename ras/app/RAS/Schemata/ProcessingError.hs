-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings. Describes messages
-- sent from halon to RAS, returning the current failure set.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module RAS.Schemata.ProcessingError where

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
        "processing_error": {
          "description": "Processing error",
          "type": "object",
          "required": true,
          "properties": {
            "device": {
              "description": "UUID of the message causing the error",
              "type": "string",
              "required": true
            },
            "error": {
              "description": "Error description",
              "type": "string",
              "required": true
            }
          }
        }
      }
    }
  }
}

|]
