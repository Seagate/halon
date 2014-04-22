#!/bin/bash -eu

`dirname $0`/dummy_mero $* > dummy_mero.stdout &
echo $! > dummy_mero.pid

