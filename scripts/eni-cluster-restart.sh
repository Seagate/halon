#!/usr/bin/env bash
set -eu -o pipefail
set -x
export PS4='+ [${FUNCNAME[0]:+${FUNCNAME[0]}:}${LINENO}] '

### Master document:
### https://docs.google.com/document/d/1kINppVHzCxegrJrNxhVoKhk7PHaMITBFhRym2H8JOeQ/edit

## pdsh hostlists:
CMU_NODE='172.16.0.41'
RC_NODE='172.16.1.1'
SSU_NODES='172.16.[1,2].[1-6]'  # includes RC_NODE
CLIENT_NODES='172.16.200.[39-54]'
CLUSTER_NODES="${SSU_NODES}${CLIENT_NODES:+,${CLIENT_NODES}}"  # w/o CMU
ALL_NODES="${CLUSTER_NODES},${CMU_NODE}"  # with CMU

## -------------------------------------------------------------------
## 1. Write down the info needed to identify the failed disk and its
##    replacement --- WWNs, serial numbers, Mero FIDs,
##    rack/controller/enclosure/slot.

# *Failed disk*
#
# SDev{0x6400000000000001:0x7a5}
# Disk{0x6b00000000000001:0x7a6}
# m0d_wwn: "0x5000c500910392c8"
# m0d_serial: "ZA202ES4"
# m0d_path: "/dev/disk/by-id/wwn-0x5000c500910392c8"
# m0d_slot: 14
#
#     Manufacturer: ATA
#     Part Number: ST10000NM0016-1T
#     Firmware Version: SNB0
#     Serial Number: ZA202ES4
# Location of failed component
#     Rack Name: Rack2
#     Enclosure Model: 5U84
#     Enclosure Location: 21U
#     Enclosure Bay: 14

# *Replacement disk*
#
# wwn: "0x5000c500932c9f9a"
# serial: "ZA20N3BQ"
# path: "/dev/disk/by-id/wwn-0x5000c500932c9f9a"

## -------------------------------------------------------------------
## 2. Stop provisioner.

mco castor puppet --off

## -------------------------------------------------------------------

## 3. Stop all `halond` processes.  Restart cluster nodes with
##    'echo b >/proc/sysrq-trigger'.

pdsh -w $ALL_NODES systemctl stop halond
pdsh -w $CLUSTER_NODES 'echo b >/proc/sysrq-trigger'

## -------------------------------------------------------------------
## 4. Backup Halon persistent state.

DATE="$(date +%Y%m%d)"
ARC="/var/mero/halon-persistence_${DATE}.tar"
time pdsh -w $RC_NODE "cd /var/lib/halon/ && tar -Scvf $ARC halon-persistence"
unset ARC

## -------------------------------------------------------------------
## 5. Backup Mero persistent state.

DIR="/var/mero/mero-persistence_${DATE}"
time pdsh -w $SSU_NODES \
     "mkdir $DIR && ls /var/mero | grep -v persistence | xargs -L1 -I{} cp -avr /var/mero/{} $DIR/{}"
unset DIR

## -------------------------------------------------------------------
## 6. Delete Halon persistent state at all cluster nodes.
##    Delete Halon decision log at RC node.

pdsh -w $ALL_NODES rm -rvf /var/lib/halon/halon-persistence
pdsh -w $RC_NODE rm -rvf /var/log/halon.decision.log

## -------------------------------------------------------------------
## 7. Blink the LED of "our" device to help human operator locate it.

sgnum=$(sg_map -x -i | awk '/8435/ { print $1 }')  # XXX What is `8435`?
wbcli $sgnum "hid_set_led 13 0"  # XXX What is `13`?
# fwdownloader -d 0 -cli hid_set_led 13 0

## -------------------------------------------------------------------
## 8. Re-insert the failed drive back into its original slot (if we
##    don't do this, SNS rebalance won't start, because Halon needs
##    disk's serial number to change in order to start rebalance).

## -------------------------------------------------------------------
## 9. Start (bootstrap) the cluster *using `mkfs-done` option*.

# The output of `hctl bootstrap cluster --dry-run` with carefully
# injected `mkfs-done`.

_hctl() {
    # The IP address is deduced by reading `/usr/bin/hctl` at CMU.
    halonctl -l 172.19.0.41:0 "$@"
}

RC=${RC_NODE/16/19}:9000

# Starting stations
_hctl -a $RC bootstrap station
# Starting satellites
_hctl -a 172.19.0.41:9000 -a $RC -a 172.19.1.2:9000 -a 172.19.1.3:9000 -a 172.19.1.4:9000 -a 172.19.1.5:9000 -a 172.19.1.6:9000 -a 172.19.2.1:9000 -a 172.19.2.2:9000 -a 172.19.2.3:9000 -a 172.19.2.4:9000 -a 172.19.2.5:9000 -a 172.19.2.6:9000 -a 172.19.200.39:9000 -a 172.19.200.40:9000 -a 172.19.200.41:9000 -a 172.19.200.42:9000 -a 172.19.200.43:9000 -a 172.19.200.44:9000 -a 172.19.200.45:9000 -a 172.19.200.46:9000 -a 172.19.200.47:9000 -a 172.19.200.48:9000 -a 172.19.200.49:9000 -a 172.19.200.50:9000 -a 172.19.200.51:9000 -a 172.19.200.52:9000 -a 172.19.200.53:9000 -a 172.19.200.54:9000 bootstrap satellite -t $RC
# Starting services
# Services for "castor-eni-a200-1-cc1.eni.intranet"
_hctl -a 172.19.0.41:9000 service sspl-hl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-1-1.eni.intranet"
_hctl -a $RC service decision-log start -f /var/log/halon.decision.log -t $RC
_hctl -a $RC service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-1-2.eni.intranet"
_hctl -a 172.19.1.2:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-1-3.eni.intranet"
_hctl -a 172.19.1.3:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-1-4.eni.intranet"
_hctl -a 172.19.1.4:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-1-5.eni.intranet"
_hctl -a 172.19.1.5:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-1-6.eni.intranet"
_hctl -a 172.19.1.6:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-2-1.eni.intranet"
_hctl -a 172.19.2.1:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-2-2.eni.intranet"
_hctl -a 172.19.2.2:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-2-3.eni.intranet"
_hctl -a 172.19.2.3:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-2-4.eni.intranet"
_hctl -a 172.19.2.4:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-2-5.eni.intranet"
_hctl -a 172.19.2.5:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# Services for "castor-eni-a200-1-ssu-2-6.eni.intranet"
_hctl -a 172.19.2.6:9000 service sspl start -u sspluser -p sspl4ever -t $RC
# load intitial data
_hctl -a $RC cluster load -f /etc/halon/halon_facts.yaml -r /etc/halon/role_maps/prov.ede
# Disable mkfs
_hctl -a $RC cluster mkfs-done --confirm
# Start cluster
_hctl -a $RC cluster start

unset RC
unset -f _hctl

## -------------------------------------------------------------------
## 10. Pull out the replacement disk (RD).

## -------------------------------------------------------------------
## 11. Wait for SNS repair to complete.

## -------------------------------------------------------------------
## 12. Insert the RD back into its slot.

## -------------------------------------------------------------------
## 13. Wait for SNS rebalance to complete.

## -------------------------------------------------------------------
## 14. *Stop* the cluster once again (similarly to step 3 above).

## -------------------------------------------------------------------
## 15. Update disk info in halon_facts.yaml --- overwrite attributes
##     of the failed disk with those of its replacement.

## -------------------------------------------------------------------
## 16. Build new Halon & Mero rpms. Copy them to cluster nodes.

## -------------------------------------------------------------------
## 17. Perform software upgrade of Mero and Halon. (Requires
##     provisioner to be off.)

## -------------------------------------------------------------------
## 18. Start the cluster *using `mkfs-done`*.

## -------------------------------------------------------------------
## 19. Start the IO (data movers).
