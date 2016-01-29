#!/bin/bash
set -eux

cd ${MERO_ROOT}

sudo rm -f /etc/mero/genders
sudo rm -f /etc/mero/conf.xc
sudo rm -f /etc/mero/disks*.conf

sudo ${BIN_DIR}/.local/bin/halonctl -a ${IP}:9010 -l ${IP}:9000 cluster dump -f /tmp/conf.xc
sudo ${BIN_DIR}/.local/bin/halonctl -a ${IP}:9010 -l ${IP}:9000 bootstrap satellite
sudo ${BIN_DIR}/.local/bin/halonctl -a ${IP}:9010 -l ${IP}:9000 service m0d start -l ${IP}@tcp:12345:34:100
sleep 2

sudo scripts/install-mero-service -u
sudo scripts/install-mero-service -l
sudo utils/m0setup -v -P 6 -N 2 -K 1 -i 1 -d /var/mero/img -s 128 -c
sudo utils/m0setup -v -P 6 -N 2 -K 1 -i 1 -d /var/mero/img -s 128

sudo rm -f /etc/mero/disks*.conf

sudo systemctl start mero-mkfs
sudo systemctl start mero-singlenode
