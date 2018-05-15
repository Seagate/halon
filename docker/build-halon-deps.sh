#!/bin/bash
set -e
set -x

# chdir into Halon top src dir
cd ${0%/*/*}

if [[ -e .stack-work ]] ; then
    rm -rf .stack-work
fi

stack setup
stack build --only-dependencies \
            --extra-include-dirs=$HOME/mero \
            --extra-lib-dirs=$HOME/mero/mero/.libs

if [[ -e docker/stack ]] ; then
    rm -rf docker/stack
fi

if [[ -e docker/stack-work ]] ; then
    rm -rf docker/stack-work
fi

mv ~/.stack docker/stack
mv .stack-work docker/stack-work
