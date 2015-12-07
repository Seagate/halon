#!/bin/bash

find . -name test_output | while read file; do
    cp -rv "$file/*" ${CIRCLE_ARTIFACTS}
done

find . -type f -name \*.log | while read file; do
    cp -v "$file" ${CIRCLE_ARTIFACTS}
done

tar czf logs.tar.gz ${CIRCLE_ARTIFACTS}
mv logs.tar.gz ${CIRCLE_ARTIFACTS}
