#!/bin/bash
set -eux

# TODO: this script should either live with st/bootstrap[-cluster].sh
# or somehow use its functionality instead of copying for the most
# part.

# TODO: We could use something like ‘expect’ to know when to call
# various commands instead of doing sleeps on a hard-coded timeout

IP=10.0.2.15
HALON_SOURCES=/mnt/home/programming/halon-clean
BIN_ROOT=$HALON_SOURCES/.stack-work/install/x86_64-linux/lts-3.11/7.10.2/bin
HALOND=$BIN_ROOT/halond
HALONCTL=$BIN_ROOT/halonctl
MERO_ROOT=$HALON_SOURCES/vendor/mero
HALON_FACTS_YAML=halon_facts.yaml

HOSTNAME="`hostname`"

main() {
    IP=$IP HALONCTL=$HALONCTL $MERO_ROOT/st/bootstrap.sh -c cluster_stop
    IP=$IP HALONCTL=$HALONCTL MERO_ROOT=$MERO_ROOT HALOND=$HALOND HALON_SOURCES=$HALON_SOURCES HOSTNAME=$HOSTNAME $MERO_ROOT/st/bootstrap.sh -c cluster_start

	sleep 30; echo "Writing to m0t1fs to check things work (required)"
	sudo dd if=/dev/urandom of=/mnt/m0t1fs/111:222 bs=4K count=100

	sleep 5; echo "Sending a drive failure notification to halon"

	sudo $MERO_ROOT/utils/m0console -s $IP@tcp:12345:34:101 -c $IP@tcp:12345:34:1001 -f 116 -v -d "[1:(^d|1:10,2)]"

	echo "Look inside /tmp/halond.log for information on how things went!"

}

function halon_facts_yaml() {
	cat << EOF
id_racks:
- rack_idx: 1
  rack_enclosures:
  - enc_idx: 1
    enc_bmc:
    - bmc_user: admin
      bmc_addr: bmc.enclosure1
      bmc_pass: admin
    enc_hosts:
    - h_cpucount: 8
      h_fqdn: $HOSTNAME
      h_memsize: 4096
      h_interfaces:
      - if_network: Data
        if_macAddress: '10-00-00-00-00'
        if_ipAddrs:
        - $IP
    enc_id: enclosure1
id_m0_servers:
- host_mem_as: 1
  host_cores:
  - 1
  lnid: $IP@tcp
  host_mem_memlock: 1
  m0h_devices:
  - m0d_serial: serial-1
    m0d_bsize: 4096
    m0d_wwn: wwn-1
    m0d_path: /dev/loop1
    m0d_size: 596000000000
  - m0d_serial: serial-2
    m0d_bsize: 4096
    m0d_wwn: wwn-2
    m0d_path: /dev/loop2
    m0d_size: 596000000000
  - m0d_serial: serial-3
    m0d_bsize: 4096
    m0d_wwn: wwn-3
    m0d_path: /dev/loop3
    m0d_size: 596000000000
  - m0d_serial: serial-4
    m0d_bsize: 4096
    m0d_wwn: wwn-4
    m0d_path: /dev/loop4
    m0d_size: 596000000000
  - m0d_serial: serial-5
    m0d_bsize: 4096
    m0d_wwn: wwn-5
    m0d_path: /dev/loop5
    m0d_size: 596000000000
  - m0d_serial: serial-6
    m0d_bsize: 4096
    m0d_wwn: wwn-6
    m0d_path: /dev/loop6
    m0d_size: 596000000000
  host_mem_rss: 1
  m0h_fqdn: $HOSTNAME
  m0h_roles:
  - name: confd
  - name: ha
  - name: mds
  - name: storage
  - name: m0t1fs
  host_mem_stack: 1
id_m0_globals:
  m0_parity_units: 1
  m0_md_redundancy: 1
  m0_data_units: 2
  m0_failure_set_gen:
    tag: Preloaded
    contents: [0, 1, 0]
EOF
}

main "$@"
