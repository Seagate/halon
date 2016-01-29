#/bin/bash

set -xe

sudo dd if=/dev/zero of=/mnt/m0t1fs/012345:67890 bs=4k
