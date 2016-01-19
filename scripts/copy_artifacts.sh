#!/bin/bash

DESTINATION=$1

mkdir -p "${DESTINATION}"

find . -name test_output | while read file; do
    cp -rv "$file"/* "${DESTINATION}"
done

mkdir "${DESTINATION}/logs"
find . -type f -name \*.log | while read file; do
    cp -v "$file" "${DESTINATION}/logs"
done

tar czf logs.tar.gz "${DESTINATION}"
mv logs.tar.gz "${DESTINATION}"
