-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings. Describes messages
-- sent from halon to RAS when a component has failed.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module RAS.Schemata.FailureNotification where

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
        "failure_notification_info": {
          "type": "object",
          "required": true,
          "properties":  {
            "enclosure_serial_number": {
              "description": "Serial number of the enclosure containing the device",
              "type": "string",
              "required": true
            },
            "failure_time": {
              "description": "The time the failure happened",
              "type": "string",
              "required": true
            },
            "state": {
              "description": "The state the device is in",
              "type": "string",
              "required": true
            },
            "reason_class": {
              "description": "Reason class of the failure",
              "type": { "enum": [ "wrong type", "broken", "teapot" ] },
              "required": true
            },
            "reason": {
              "description": "Failure description",
              "type": "string",
              "required": true
            },
            "root_cause": {
              "description": "Cause for failure",
              "type": "string",
              "required": true
            }
          }
        },
        "failure_notification_type": {
          "type": "object",
          "required": true,
          "properties": {
            "disk": {
              "index": {
                "description": "Index of the disk in the enclosure",
                "type": "number",
                "required": true
              },
              "drawer": {
                "description": "Drawer number containing the disk",
                "type": "number",
                "required": true
              }
            },
            "controller": {
              "index": {
                "description": "Index of the controller in the enclosure",
                "type": "number",
                "required": true
              },
              "controller_serial_number": {
                "description": "Serial number of the controller",
                "type": "string",
                "required": true
              },
              "hostname": {
                "description": "Hostname associated with the controller",
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

|]
