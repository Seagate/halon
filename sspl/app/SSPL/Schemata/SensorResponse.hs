-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schemata.SensorResponse where

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
          "uuid": {
            "description": "Universally Unique ID of message",
            "type": "string",
            "required": false
          }
        },

        "sensor_response_type": {
          "type" : "object",
          "required" : true,
          "properties": {

            "disk_status_drivemanager": {
              "type" : "object",
              "properties": {
                "diskNum" : {
                  "description" : "Drive Number within the enclosure",
                  "type" : "number",
                  "required" : true
                },
                "enclosureSN" : {
                  "description" : "Enclosure Serial Number",
                  "type" : "string",
                  "required" : true
                },
                "diskStatus" : {
                  "description" : "Disk Status",
                  "type" : "string",
                  "required" : true
                }
              }
            },

            "disk_status_hpi": {
              "type" : "object",
              "properties": {
                "hostId" : {
                  "description" : "Host ID of node",
                  "type" : "string",
                  "required" : true
                },
                "deviceId" : {
                  "description" : "Drive Identifier",
                  "type" : "string",
                  "required" : true
                },
                "drawer" : {
                  "description" : "Drawer number of drive",
                  "type" : "integer",
                  "required" : true
                },
                "location" : {
                  "description" : "Location number of drive",
                  "type" : "integer",
                  "required" : true
                },
                "manufacturer" : {
                  "description" : "Manufacturer of the drive",
                  "type" : "string",
                  "required" : true
                },
                "productName" : {
                  "description" : "Product name of the drive",
                  "type" : "string",
                  "required" : true
                },
                "productVersion" : {
                  "description" : "Version of the drive",
                  "type" : "string",
                  "required" : true
                },
                "serialNumber" : {
                  "description" : "Serial Number of the drive",
                  "type" : "string",
                  "required" : true
                },
                "wwn" : {
                  "description" : "wwn of the drive",
                  "type" : "string",
                  "required" : true
                }
              }
            },

            "service_watchdog": {
              "type": "object",
              "properties": {
                "service_name": {
                  "description": "Identify the service with a state change",
                  "type": "string",
                  "required": true
                },
                "service_state": {
                  "description": "Current state of the service",
                  "type": "string",
                  "required": true
                },
                "previous_service_state": {
                  "description": "Previous state of the service",
                  "type": "string",
                  "required": true
                }
              }
            },

            "host_update": {
              "type" : "object",
              "properties": {
                "hostId" : {
                  "description" : "Hostname of system",
                  "type" : "string",
                  "required": true
                },
                "localtime" : {
                  "description" : "Local time on system",
                  "type" : "string",
                  "required": true
                },
                "bootTime" : {
                  "description" : "Time host was started",
                  "type" : "string"
                },
                "upTime" : {
                  "description" : "Time since host was started in secs",
                  "type" : "number"
                },
                "uname" : {
                  "description" : "OS system information",
                  "type" : "string"
                },
                "freeMem" : {
                  "description" : "Amount of free memory",
                  "type" : "object",
                  "properties": {
                    "value": {
                      "type" : "integer"
                    },
                    "units": {
                      "oneOf": [
                        { "$ref": "#/units/GB" },
                        { "$ref": "#/units/KB" },
                        { "$ref": "#/units/MB" }
                      ]
                    }
                  }
                },
                "totalMem" : {
                  "description" : "Total memory available",
                  "type" : "object",
                  "properties": {
                    "value": {
                      "type" : "integer"
                    },
                    "units": {
                      "oneOf": [
                        { "$ref": "#/units/GB" },
                        { "$ref": "#/units/KB" },
                        { "$ref": "#/units/MB" }
                      ]
                    }
                  }
                },
                "loggedInUsers" : {
                  "description" : "List of logged in users",
                  "type" : "array"
                },
                "processCount" : {
                  "description" : "Total number of processes",
                  "type" : "integer"
                },
                "runningProcessCount" : {
                  "description" : "Total number of running processes",
                  "type" : "integer"
                }
              }
            },

            "local_mount_data" : {
              "description" : "Local mount data",
              "type" : "object",
              "properties": {
                "hostId" : {
                  "description" : "Hostname of system",
                  "type" : "string",
                  "required": true
                },
                "localtime" : {
                  "description" : "Local time on system",
                  "type" : "string",
                  "required": true
                },
                "freeSpace": {
                  "type" : "object",
                  "properties": {
                    "value": {
                      "type" : "integer"
                    },
                    "units": {
                      "oneOf": [
                        { "$ref": "#/units/GB" },
                        { "$ref": "#/units/KB" },
                        { "$ref": "#/units/MB" }
                      ]
                    }
                  }
                },
                "freeInodes": {
                  "type" : "integer"
                },
                "freeSwap": {
                  "type" : "object",
                  "properties": {
                    "value": {
                      "type" : "integer"
                    },
                    "units": {
                      "oneOf": [
                      { "$ref": "#/units/GB" },
                      { "$ref": "#/units/KB" },
                      { "$ref": "#/units/MB" }
                      ]
                    }
                  }
                },
                "totalSpace": {
                  "type" : "object",
                  "properties": {
                    "value": {
                      "type" : "integer"
                    },
                    "units": {
                      "oneOf": [
                        { "$ref": "#/units/GB" },
                        { "$ref": "#/units/KB" },
                        { "$ref": "#/units/MB" }
                      ]
                    }
                  }
                },
                "totalSwap": {
                  "type" : "object",
                  "properties": {
                    "value": {
                      "type" : "integer"
                    },
                    "units": {
                      "oneOf": [
                        { "$ref": "#/units/GB" },
                        { "$ref": "#/units/KB" },
                        { "$ref": "#/units/MB" }
                      ]
                    }
                  }
                }
              }
            },

            "cpu_data" : {
              "description" : "CPU Data",
              "type" : "object",
              "properties": {
                "hostId" : {
                  "description" : "Hostname of system",
                  "type" : "string",
                  "required": true
                },
                "localtime" : {
                  "description" : "Local time on system",
                  "type" : "string",
                  "required": true
                },
                "csps": {
                  "type" : "integer"
                },
                "idleTime": {
                  "type" : "integer"
                },
                "interruptTime": {
                  "type" : "integer"
                },
                "iowaitTime ": {
                  "type" : "integer"
                },
                "niceTime": {
                  "type" : "integer"
                },
                "softirqTime": {
                  "type" : "integer"
                },
                "stealTime": {
                  "type" : "integer"
                },
                "systemTime": {
                  "type" : "integer"
                },
                "userTime": {
                  "type" : "integer"
                },
                "coreData": {
                  "description" : "CPU Core Data",
                  "type": "array",
                  "minItems": 1,
                  "items": {
                    "type" : "object",
                    "properties": {
                      "coreId" : {
                        "type" : "integer"
                      },
                      "load1MinAvg" : {
                        "type" : "integer"
                      },
                      "load5MinAvg" : {
                        "type" : "integer"
                      },
                      "load15MinAvg" : {
                        "type" : "integer"
                      },
                      "ips" : {
                        "type" : "integer"
                      }
                    }
                  }
                }
              }
            },

            "if_data" : {
              "description" : "Network Interface Data",
              "type" : "object",
              "properties": {
                "hostId" : {
                  "description" : "Hostname of system",
                  "type" : "string",
                  "required": true
                },
                "localtime" : {
                  "description" : "Local time on system",
                  "type" : "string",
                  "required": true
                },
                "interfaces": {
                  "type": "array",
                  "minItems": 1,
                  "items": {
                    "type" : "object",
                    "properties": {
                      "ifId " : {
                        "type" : "string"
                      },
                      "networkErrors" : {
                        "type" : "integer"
                      },
                      "droppedPacketsIn" : {
                        "type" : "integer"
                      },
                      "packetsIn" : {
                        "type" : "integer"
                      },
                      "trafficIn" : {
                        "type" : "integer"
                      },
                      "droppedPacketsOut" : {
                        "type" : "integer"
                      },
                      "packetsOut" : {
                        "type" : "integer"
                      },
                      "trafficOut" : {
                        "type" : "integer"
                      }
                    }
                  }
                }
              }
            },

            "raid_data" : {
              "description" : "RAID Data",
              "type" : "object",
              "properties" : {
                "hostId" : {
                  "description" : "Hostname of system",
                  "type" : "string",
                  "required": true
                },
                "mdstat" : {
                  "description" : "/proc/mdstat containing state information about RAID",
                  "type" : "string"
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
