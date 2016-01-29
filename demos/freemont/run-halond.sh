#!/bin/bash
set -xe

sudo killall halond || true 
sudo rm -rf halon-persistence/ 
sudo systemctl start mero-kernel
sudo ${BIN_DIR}/.local/bin/halond -l ${IP}:9010 > /tmp/halond.log 2>&1 &
sleep 1
sleep 1
${BIN_DIR}/.local/bin/halonctl -a ${IP}:9010 -l ${IP}:9001 bootstrap station
${BIN_DIR}/.local/bin/halonctl -a ${IP}:9010 -l ${IP}:9001 cluster load -f $(pwd)/halon_facts.yaml 
# tail -f -n+0 /tmp/halond.log
