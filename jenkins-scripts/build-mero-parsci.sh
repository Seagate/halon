#!/bin/bash
set -eu

DEPENDENCY_REPO=$1
DEPENDENCY_BRANCH=$2

update() {
  if [ -z "$(ls -A "$1")" ]
  then
    # pg73-v0 can do this very fast since home folders are local there
    ssh pg73-v0 "cd `pwd`; git clone -l -b $DEPENDENCY_BRANCH \"$DEPENDENCY_REPO/$1\" \"$1\""
  else
    CURRENT=`pwd`
    cd "$1"
    git pull origin $DEPENDENCY_BRANCH
    cd "$CURRENT"
  fi
} 

update extra-libs/cunit
update extra-libs/db4
update extra-libs/galois
update extra-libs/rvm
update extra-libs/yaml

git pull $MERGE_REMOTE $MERGE_BRANCH

./autogen.sh
./configure --${m0_asserts}-m0-asserts --enable-debug
make
