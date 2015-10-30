#!/bin/bash -ex
CONFC_TOP=`pwd`
BUILD_DIR=${CONFC_TOP}/$1
TEST_DIR=$(dirname $BUILD_DIR)/test

mkdir -p $TEST_DIR
cd $TEST_DIR

SUDO="sudo LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
$SUDO sh -c \
   "( cd /tmp && $BUILD_DIR/testconf/testconf `sudo lctl list_nids | head -1`:12345:35:401 `sudo lctl list_nids | head -1`:12345:44:101 )" > testconfc_out.txt
