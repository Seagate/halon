-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- JSON Schema used to generate language bindings.

{-# LANGUAGE QuasiQuotes     #-}
{-# LANGUAGE TemplateHaskell #-}

module SSPL.Schema where

import Data.Aeson.Schema

monitorResponse = [schemaQQ|
{
  "$schema":"http://json-schema.org/draft-03/schema#",
  "type":"object",
  "properties": {
    "sspl_ll_host": {
          "schema_version": {
              "description" :"SSPL JSON Schema Version",
              "type" : "string",
              "required" : true
          },
          "sspl_version": {
              "description" : "SSPL Version",
              "type" : "string",
              "required" : true
          }
      },

    "monitor_msg_type": {
      "type" : "object",
      "required" : true,
      "properties": {
        "disk_status_drivemanager": {
          "type" : "object",
          "properties": {
            "diskNum" : {
                "type" : "number",
                "required" : true
            },
            "enclosureSN" : {
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

        "host_update": {
          "type" : "object",
          "properties": {
            "bootTime" : {
              "description" : "Time Since Host Was Started",
              "type" : "string"
            },
            "upTime" : {
              "description" : "Time Since Host Was Started in Secs",
              "type" : "integer"
            },
            "uname" : {
              "description" : "OS System Information",
              "type" : "string"
            },
            "freeMem" : {
              "description" : "Amount of Free Memory",
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
              "description" : "Total Memory Available",
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
              "description" : "Total Number of Processes",
              "type" : "integer"
            },
            "runningProcessCount" : {
              "description" : "Total Number of Running Processes",
              "type" : "integer"
            },
            "localMountData" : {
              "description" : "Local Mount Data",
              "type" : "object",
              "properties": {
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
            "cpuData" : {
              "description" : "CPU Data",
              "type" : "object",
              "properties": {
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

            "ifData" : {
              "description" : "Network Interface Data",
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
                    "dopppedPacketsOut" : {
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
          }
        }
      }
    }
  }

  |]
