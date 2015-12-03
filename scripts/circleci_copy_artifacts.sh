#!/bin/bash

# Truncate log file.
cat < /dev/null > ${CIRCLE_ARTIFACTS}/tests.log

find . -path '*/test_output/*' | while read file; do
    echo Copying "$file" ...
    echo TEST "$file" >> ${CIRCLE_ARTIFACTS}/tests.log
    cat < "$file" >> ${CIRCLE_ARTIFACTS}/tests.log
    echo >> ${CIRCLE_ARTIFACTS}/tests.log
done

find . -type f -name \*.log | while read file; do
    cp -v "$file" ${CIRCLE_ARTIFACTS}
done
