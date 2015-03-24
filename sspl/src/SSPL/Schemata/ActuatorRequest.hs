-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schemata.ActuatorRequest where

import Data.Aeson.Schema

schema = [schemaQQ|
{
  "$schema":"http://json-schema.org/draft-03/schema#",
  "type":"object",
  "properties": {
    "sspl_ll_msg_header": {
      "required" : true,
          "schema_version": {
              "description" :"SSPL JSON Schema Version",
              "type" : "string",
              "required" : true
          },
          "sspl_version": {
              "description" : "SSPL Version",
              "type" : "string",
              "required" : true
          },
          "msg_version" : {
        "description" : "Message Version",
        "type" : "string",
        "required" : true
      },
      "uuid" : {
        "description" : "Universally Unique ID for Lifetime of Request",
        "type" : "string",
        "required" : false
      }
    },

    "sspl_ll_debug": {
          "debug_component" : {
        "description" : "Used to identify the component to debug",
        "type" : "string",
        "required" : false
      },
      "debug_enabled" : {
        "description" : "Control persisting debug mode",
        "type" : "boolean",
        "required" : false
      }
    },

    "actuator_request_type": {
      "type" : "object",
      "required" : true,
      "additionalProperties" : false,
      "properties": {

        "logging": {
          "type" : "object",
          "additionalProperties" : false,
          "properties": {
            "log_type" : {
              "description" : "Identify the type of log message",
                "type" : "string",
                "required" : true
            },
            "log_msg" : {
              "description" : "The message to be logged",
                  "type" : "string",
                  "required" : true
            }
          }
        },

        "thread_controller": {
          "type" : "object",
          "additionalProperties" : false,
          "properties": {
            "module_name" : {
              "description" : "Identify the thread to be managed by its class name",
                "type" : "string",
                "required" : true
            },
            "thread_request" : {
              "description" : "Action to be applied to thread: start | stop | restart | status",
                  "type" : "string",
                  "required" : true
            }
          }
        },

        "systemd_service": {
          "type" : "object",
          "additionalProperties" : false,
          "properties": {
            "service_name" : {
              "description" : "Identify the service to be managed",
                "type" : "string",
                "required" : true
            },
            "systemd_request" : {
              "description" : "Action to be applied to service: start | stop | restart | status",
                  "type" : "string",
                  "required" : true
            }
          }
        }
      }
    }
  }
}
  |]
