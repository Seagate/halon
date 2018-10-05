#!/usr/bin/env bash
set -eux

ENCLOSURE="ENC#0"
SERIAL="STOBAD001"
SLOT_INDEX=1
FILE="/mnt/m0t1fs/fedcba98:76543210"

wait_for_state() {
	state=$1
	serial=$2

	while true; do
		status=$(hctl mero status -d | grep "$state.*StorageDevice.*$serial" || true)
		echo "$status"
		if [ -n "$status" ]; then
			break;
		fi
	done
}

time sudo dd if=/dev/zero of="$FILE" bs=32k count=100
hctl mero drive update-presence --slot-enclosure "$ENCLOSURE" --serial "$SERIAL" --slot-index "$SLOT_INDEX"
wait_for_state Repaired "$SERIAL"
sudo hctl mero vars set --disable-smart-check True
hctl mero drive update-presence --slot-enclosure "$ENCLOSURE" --serial "$SERIAL" --slot-index "$SLOT_INDEX" --is-powered --is-installed
hctl mero drive update-status --slot-enclosure "$ENCLOSURE" --serial "$SERIAL" --slot-index "$SLOT_INDEX" --status OK
wait_for_state Online "$SERIAL"
echo "Test status: SUCCESS"
