-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schemata.SensorRequest where

import Data.Aeson.Schema

schema = [schemaQQ|
{
  "$schema": "http://json-schema.org/draft-03/schema#",
  "id": "http://json-schema.org/draft-03/schema#",

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
      "type": "object",
      "required": true,
      "properties": {
        "sspl_ll_msg_header": {
          "required": true,
          "schema_version": {
            "description": "SSPL JSON Schema Version",
            "type": "string",
            "required": true
          },
          "sspl_version": {
            "description": "SSPL Version",
            "type": "string",
            "required": true
          },
          "msg_version": {
            "description": "Message Version",
            "type": "string",
            "required": true
          },
          "msg_expiration": {
            "description": "Number of seconds for message to complete the desired action before returning an error code",
            "type": "integer",
            "required": false
          },
          "uuid": {
            "description": "Universally Unique ID of message",
            "type": "string",
            "required": false
          }
        },

        "sspl_ll_debug": {
          "debug_component": {
            "description": "Used to identify the component to debug",
            "type": "string",
            "required": false
          },
          "debug_enabled": {
            "description": "Control persisting debug mode",
            "type": "boolean",
            "required": false
          }
        },

        "sensor_request_type": {
          "type": "object",
          "required": true,
          "additionalProperties": false,
          "properties": {

            "node_data": {
              "type": "object",
              "additionalProperties": false,
              "properties": {
                "sensor_type": {
                  "description": "Request sensor data; cpu_data, etc.",
                  "type": "string",
                  "required": true
                }
              }
            }
          }
        }
      }
    }
  }
}
  |]
