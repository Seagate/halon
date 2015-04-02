#!/bin/bash

rm -rf tmp-freeze
mkdir tmp-freeze

cd tmp-freeze
cabal sandbox init --sandbox=$(pwd)/../.cabal-sandbox/ 

cp ../mero-halon/mero-halon.cabal ./freeze.cabal

cabal freeze

# this cabal freeze will contain freezes for
# packages that are version controlled by
# git commit, not by version number; these
# should not appear in the freeze file.

for p in $@; do
  echo removing package $p
  sed -i "/ *$p =.*/d" cabal.config
done

diff cabal.config ../cabal.config
RC=$?


if [ "$RC" == "0" ] ; then
  echo No differences in freeze.
else
  echo Freezes differ
fi

rm -rf tmp-freeze
exit $RC
