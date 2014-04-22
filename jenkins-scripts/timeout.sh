#!/usr/bin/env bash
set -e

if [ "-s" == "$1" ]
then
    SUDO=sudo
    shift 1
else
    SUDO=
fi

if [ -z "$2" ]
then
    echo "USAGE: $(basename "$0") [-s] <timeout_seconds> command..."
    echo ""
    echo "DESCRIPTION"
    echo -e "\tKills command and all its children processes if command does not"
    echo -e "\tfinish within the specified timeout in seconds."
    echo ""
    echo -e "\t-s Run the kill command with sudo."
    exit 1
fi

KILLTREE=$(dirname "$0")/killtree.sh

${@:2} &
s=$!
trap "${SUDO} ${KILLTREE} $s" SIGINT SIGTERM
(sleep $1; echo "$0: (timeout)"; kill $$ &> /dev/null ) &
t=$!
trap "${SUDO} ${KILLTREE} $s; kill $t &> /dev/null " SIGINT SIGTERM
wait $s
r=$?
trap - SIGINT SIGTERM
kill $t &> /dev/null
exit $r
