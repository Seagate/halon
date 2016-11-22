#!/usr/bin/env bash
# set -x

function intercalate { local IFS="$1"; shift; echo "$*"; }

# Current directory
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

if [ -z "$HALON_BUILD_ENV" ]; then
  HALON_BUILD_ENV=bare
fi

STACK=$(which stack)
declare -a FLAGS

#EXTRA_INCLUDE_DIRS=("$DIR/rpclite/rpclite")
FLAGS=("--flag confc:mero --flag mero-halon:mero")

if [ $HALON_BUILD_ENV = "bare" ]; then
  if [ -z "$MERO_ROOT" ]; then
    echo "MERO_ROOT be defined and point to the Mero source directory."
    exit 1
  fi
  FLAGS=("${FLAGS[@]}" "--no-docker")
  export PKG_CONFIG_PATH="${MERO_ROOT}"
  export LD_LIBRARY_PATH="${MERO_ROOT}/mero/.libs"
fi

if [ $HALON_BUILD_ENV = "prod" ]; then
  FLAGS=("${FLAGS[@]}" "--no-docker")
fi

if [ $HALON_BUILD_ENV = "docker" ]; then
  FLAGS=("${FLAGS[@]}" "--docker")
fi

if [ $HALON_BUILD_ENV = "nix" ]; then
  FLAGS=("${FLAGS[@]}" "--nix" "--no-docker")
fi

$STACK "$@" $(intercalate ' ' ${FLAGS[@]})
