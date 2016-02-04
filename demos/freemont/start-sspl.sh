#!/bin/bash

set -xe

echo "Starting RabbitMQ broker"
sudo systemctl start rabbitmq-server
sleep 1
sleep 1

echo "Starting HA-SSPL service"
${BIN_DIR}/.local/bin/halonctl -a ${IP}:9010 -l ${IP}:9001 service sspl start \
	--hostname localhost \
	--username guest \
	--password guest \
	--vhost /
sleep 1
sleep 1
