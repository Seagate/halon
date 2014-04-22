#!/usr/bin/env bash
set -eu

killtree() {
    local pid
    for pid; do
        kill -stop $pid
        local cpid
        for cpid in $(pgrep -P $pid); do
            killtree $cpid
        done
        kill $pid                   # NOTE. SIGTERM doesn't kill stopped process
        kill -cont $pid             # So I added sending SIGCONT
    done
}

killtree $1
