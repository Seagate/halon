#!/bin/bash
#
# Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
# License   : Apache License, Version 2.0.
#
# Find all files lacking an appropriate copyright declaration.

MUST_HAVE_COPYRIGHT=$(git ls-files | grep -E '\.(hs|c|h|sh|hsc|cabal)$')
LACK_COPYRIGHT=$(grep -LE "Copyright.*(c|C|©)" $MUST_HAVE_COPYRIGHT)

# Exclude tiny utility files (less than 10 lines).
LACK_COPYRIGHT=$(
    for i in $LACK_COPYRIGHT; do wc -l $i; done |
    while read n file; do [[ $n -lt 10 ]] || echo $file; done)

if [[ $LACK_COPYRIGHT ]]; then
  echo "Some files lack a copyright statement:"
  echo $LACK_COPYRIGHT | tr ' ' '\n'
  exit 1
fi
