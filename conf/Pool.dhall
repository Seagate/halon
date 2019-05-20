{ name : Text
, disks : List { host : Text, filter : Text }
, dataUnits : Natural
, parityUnits : Natural
, allowedFailures : Optional ./Failures.dhall
}
