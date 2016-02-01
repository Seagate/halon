#!/bin/bash

set -xe
sudo pkill halond || echo "halon was stopped."
sudo systemctl stop mero-singlenode
