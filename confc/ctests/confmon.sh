#!/bin/bash -e

NID=`lctl list_nids | head -1`
while ./conf_poll_once $NID:12345:34:401 $NID:12345:34:1 >> /dev/null 2>&1; do sleep 10; done

