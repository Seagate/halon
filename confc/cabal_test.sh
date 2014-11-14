#!/bin/bash -ex
CONFC_TOP=`pwd`
BUILD_DIR=$1
TEST_DIR=$(dirname $BUILD_DIR)/test

mkdir -p $TEST_DIR
cd $TEST_DIR

BUILD_DIR=../build
SUDO="sudo LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
$SUDO sh -c \
   "$BUILD_DIR/testconfc/testconfc `sudo lctl list_nids | head -1`:12345:35:401 `sudo lctl list_nids | head -1`:12345:34:1001" > testconfc_out.txt
make -C $CONFC_TOP/ctests runconfc_test_file
diff -c $CONFC_TOP/ctests/confc_test_out.txt testconfc_out.txt
