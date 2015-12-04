#!/bin/bash

# Truncate log file.
cat < /dev/null > ${CIRCLE_ARTIFACTS}/tests.log

find . -path '*/test_output/*' | while read file; do
    cp -v "$file" ${CIRCLE_ARTIFACTS}
done

find . -type f -name \*.log | while read file; do
    cp -v "$file" ${CIRCLE_ARTIFACTS}
done
