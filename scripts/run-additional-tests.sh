#!/bin/bash

if [ ! -d $MERO_ROOT ] ; then
	echo "MERO_ROOT environment variable should be set."
	exit 1;
fi

if [[ `id -u` != 0  ]] ; then
 	echo "You must be supervisor in order to run tests."
	exit 1
fi

echo "rpclite tests:"
pushd rpclite/rpclite
mkdir -p /var/mero/halon
rm -rf /var/mero/halon/*
for i in 4 7 9 ; do
   make runtest$i
   ret=$?
   if [[ $ret != 0 ]]; then
	echo "Test failed."
	exit 1
   fi
done;
popd
