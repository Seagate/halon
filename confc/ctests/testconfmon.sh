#!/bin/bash -u

[ `id -u` -eq 0 ] || die 'Must be run by superuser'

export SANDBOX_DIR=/tmp/_m0-sandbox2
export ST=../../network-transport-rpc/rpclite/st

echo -n starting confd ...
$ST sstart confd
echo done
echo -n starting confmon ...
./confmon.sh &
CONFMON_PID=$!
echo done. pid $CONFMON_PID
echo waiting a few seconds ...
sleep 3
if [ -f $SANDBOX_DIR/confd.pid ]
  then echo " " confd is still alive
  else echo " " error: confd has stopped; exit 1
fi

kill -0 $CONFMON_PID &> /dev/null || true
if [ $? == 0 ]
  then echo " " confmon is still alive
  else echo " " error: confmon has stopped; ./st sstop confd; exit 1
fi

echo -n stopping confd ...
$ST sstop confd || true
if [ -f $SANDBOX_DIR/confd.pid ]
  then echo error: confd is still alive; exit 1
  else echo done
fi

echo -n waiting a bit more ...
sleep 10
kill -0 $CONFMON_PID &> /dev/null
if [ $? == 0 ]
  then echo error: confmon is still alive; exit 1
  else echo confmon has stopped
fi


