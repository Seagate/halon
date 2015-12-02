#!/bin/bash

mkdir artifacts
mkdir artifacts/logs
find . -name test_output | while read dir ; do \
  target="artifacts/$(echo $dir | cut --delimiter="/" --fields=2)"; \
  mkdir "$target"; \
  cp -av "$dir" "$target" ; \
done
find . -type f -name \*.log \( -regex '.*/artifacts.*' -prune -o -print \) | while read l ; do \
  cp -v "$l" artifacts/logs/ ; \
done

renameFiles() {
  ls -A "$1" | while read l ; do \
    n=$(echo $l | sed s/[^-a-zA-Z0-9/.]/_/g)
    if [[ "$n" != "$l" ]] ; then
      while test -f "$1/$n" ; do
        n=${n}_
      done
      mv -v "$1/$l" "$1/$n"
    fi
    if [[ -d "$1/$n" ]] ; then
        renameFiles "$1/$n"
    fi
  done
}

renameFiles artifacts

cp -r artifacts ${CIRCLE_ARTIFACTS}
