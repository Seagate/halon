-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schemata.ActuatorResponse where

import Data.Aeson.Schema

schema = [schemaQQ|
{
  "$schema": "http://json-schema.org/draft-03/schema#",
  "type": "object",
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
      "uuid": {
        "description": "Universally Unique ID for Lifetime of Initial Request",
        "type": "string",
        "required": false
      }
    },

    "actuator_response_type": {
      "type": "object",
      "required": true,
      "properties": {

        "ack": {
          "type": "object",
          "properties": {
            "ack_type": {
              "description": "Identify the type of acknowledgement",
              "type": "string",
              "required": true
            },
            "ack_msg": {
              "description": "Message describing acknowledgement",
              "type": "string",
              "required": true
            }
          }
        },

        "thread_controller": {
          "type": "object",
          "properties": {
            "module_name": {
              "description": "Identify the module to be managed by its class name",
              "type": "string",
              "required": true
            },
            "thread_response": {
              "description": "Response from action applied: start | stop | restart | status",
              "type": "string",
              "required": true
            }
          }
        },

        "service_controller": {
          "type": "object",
          "properties": {
            "service_name": {
              "description": "Identify the service to be managed",
              "type": "string",
              "required": true
            },
            "service_response": {
              "description": "Response from action applied: start | stop | restart | status",
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
