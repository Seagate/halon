#!/bin/bash -ex
BUILD_DIR=$1
TEST_DIR=$(dirname $BUILD_DIR)/test

mkdir -p $TEST_DIR
cd $TEST_DIR

BUILD_DIR=../build
SUDO="sudo LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
$SUDO $BUILD_DIR/TestCH/TestCH
$SUDO $BUILD_DIR/TestNT/TestNT
$SUDO $BUILD_DIR/testtransport/testtransport "0@lo:12345:34:2"
