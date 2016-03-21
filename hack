#!/usr/bin/env bash
# set -x

function intercalate { local IFS="$1"; shift; echo "$*"; }

# Current directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -z "$HALON_BUILD_ENV" ]; then
  HALON_BUILD_ENV=bare
fi

STACK=$(which stack)
declare -a EXTRA_LIB_DIRS
declare -a EXTRA_INCLUDE_DIRS
declare -a FLAGS

EXTRA_INCLUDE_DIRS=("$DIR/rpclite/rpclite")
FLAGS=("--flag *:mero")

if [ $HALON_BUILD_ENV = "bare" ]; then
  if [ -z "$MERO_ROOT" ]; then
    echo "MERO_ROOT be defined and point to the Mero source directory."
    exit 1
  fi
  FLAGS=("${FLAGS[@]}" "--no-docker")
  EXTRA_LIB_DIRS=("${EXTRA_LIB_DIRS[@]}" "$MERO_ROOT/mero/.libs")
  EXTRA_INCLUDE_DIRS=("${EXTRA_INCLUDE_DIRS[@]}" "$MERO_ROOT" "$MERO_ROOT/extra-libs/galois/include")
fi

if [ $HALON_BUILD_ENV = "prod" ]; then
  FLAGS=("${FLAGS[@]}" "--no-docker")
  # EXTRA_LIB_DIRS=("${EXTRA_LIB_DIRS[@]}" "$MERO_ROOT/mero/.libs")
  EXTRA_INCLUDE_DIRS=("${EXTRA_INCLUDE_DIRS[@]}" "/usr/lib/mero")
fi

if [ $HALON_BUILD_ENV = "docker" ]; then
  FLAGS=("${FLAGS[@]}" "--docker")
  EXTRA_LIB_DIRS=("${EXTRA_LIB_DIRS[@]}" "/mero/mero/.libs")
  EXTRA_INCLUDE_DIRS=("${EXTRA_INCLUDE_DIRS[@]}" "/mero" "/mero/extra-libs/galois/include")
fi

if [ $HALON_BUILD_ENV = "nix" ]; then
  FLAGS=("${FLAGS[@]}" "--nix" "--no-docker")
fi

EXTRA_LIB_DIRS=("${EXTRA_LIB_DIRS[@]/#/--extra-lib-dirs=}")
EXTRA_INCLUDE_DIRS=("${EXTRA_INCLUDE_DIRS[@]/#/--extra-include-dirs=}")

$STACK $(intercalate ' ' ${EXTRA_LIB_DIRS[@]}) $(intercalate ' ' ${EXTRA_INCLUDE_DIRS[@]}) "$@" $(intercalate ' ' ${FLAGS[@]})
