#!/bin/bash

TS=127.0.0.1:9010
SAT=127.0.0.1:9020

rm -f /tmp/decision.log

HALOND="$HALON_ROOT/halond"
HALONCTL="$HALON_ROOT/halonctl"

$HALOND -l $TS > /tmp/TS.log 2>&1 &
$HALOND -l $SAT > /tmp/satellite.log 2>&1 &

$HALONCTL -a $SAT bootstrap satellite -t $TS
$HALONCTL -a $TS bootstrap station

$HALONCTL -a $SAT service decision-log start -t $TS -f /tmp/decision.log
$HALONCTL -a $SAT service frontier start -t $TS -p 9028
