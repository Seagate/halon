#!/bin/bash -ex
CONFC_TOP=`pwd`
BUILD_DIR=${CONFC_TOP}/$1
TEST_DIR=$(dirname $BUILD_DIR)/test
DEV=$(sudo lctl list_nids | head -1)

mkdir -p $TEST_DIR
cd $TEST_DIR

SUDO="sudo LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
$SUDO sh -c \
   "( cd /tmp && $BUILD_DIR/unit-tests/unit-tests )" > unit-tests.txt || exit 1
$SUDO sh -c \
   "( cd /tmp && $BUILD_DIR/testconf/testconf $DEV:12345:35:401 $DEV:12345:44:101 )" > testconfc_out.txt || exit 1
$SUDO sh -c \
   "( cd /tmp && $BUILD_DIR/conf-test/conf-test $DEV:12345:35:401 $DEV:12345:44:101 $DEV:12345:41:201 )" > conftest_out.txt || exit 1
$SUDO sh -c \
   "( cd /tmp && $BUILD_DIR/testspiel/testspiel $DEV:12345:35:401 $DEV:12345:44:101 $DEV:12345:41:201 )" > testspiel_out.txt || exit 1
$SUDO sh -c \
   "( cd /tmp && $BUILD_DIR/testcopyconf/testcopyconf $DEV:12345:35:401 $DEV:12345:44:101 $DEV:12345:41:201 )" > testcopyconf_out.txt || exit 1
