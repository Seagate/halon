#!/bin/bash
set -eux

#IP=172.16.1.212
#HALOND=/home/mask/.local/bin/halond
#HALONCTL=/home/mask/.local/bin/halonctl
#HALON_SOURCES=/work/halon
#HALON_FACTS_YAML=halon_facts.yaml

IP=10.0.2.15
BIN_ROOT=/mnt/home/programming/halon-clean/.stack-work/install/x86_64-linux/lts-3.11/7.10.2/bin
HALOND=$BIN_ROOT/halond
HALONCTL=$BIN_ROOT/halonctl
HALON_SOURCES=/mnt/home/programming/halon-clean
MERO_ROOT=/mnt/home/programming/halon-clean/vendor/mero
HALON_FACTS_YAML=halon_facts.yaml

HOSTNAME="`hostname`"

main() {
	sudo killall halond || true
	sleep 1
	sudo rm -rf halon-persistence
	sudo systemctl stop mero-kernel &
	sudo killall -9 lt-m0d m0d lt-m0mkfs m0mkfs || true
	wait

        pushd $MERO_ROOT
	sudo scripts/install-mero-service -u
	sudo scripts/install-mero-service -l
	sudo utils/m0setup -v -P 6 -N 2 -K 1 -i 1 -d /var/mero/img -s 128 -c
	sudo utils/m0setup -v -P 6 -N 2 -K 1 -i 1 -d /var/mero/img -s 128
        popd

	sudo rm -vf /etc/mero/genders
	sudo rm -vf /etc/mero/conf.xc
	sudo rm -vf /etc/mero/disks*.conf

	halon_facts_yaml > $HALON_FACTS_YAML

	sudo $HALOND -l $IP:9000 >& /tmp/halond.log &
	true
	sleep 2
	sudo $HALONCTL -l $IP:9010 -a $IP:9000 bootstrap station
	sudo $HALONCTL -l $IP:9010 -a $IP:9000 bootstrap satellite -t $IP:9000
	sudo $HALONCTL -l $IP:9010 -a $IP:9000 cluster load -f $HALON_FACTS_YAML -r $HALON_SOURCES/mero-halon/scripts/mero_provisioner_role_mappings.ede

	sleep 30; echo "Fail (start)"
	sudo $MERO_ROOT/utils/m0console -f 116 -s 10.0.2.15@tcp:12345:34:101 -c 10.0.2.15@tcp:12345:31:100 -d '[6:(^d|1:8,1),(^d|1:10,1),(^d|1:12,1),(^d|1:14,1),(^d|1:16,1),(^d|1:18,2)]'
	sleep 5; echo "Transient (halt)"
	sudo $MERO_ROOT/utils/m0console -f 116 -s 10.0.2.15@tcp:12345:34:101 -c 10.0.2.15@tcp:12345:31:100 -d '[6:(^d|1:8,1),(^d|1:10,1),(^d|1:12,1),(^d|1:14,1),(^d|1:16,1),(^d|1:18,3)]'
	sleep 5; echo "Online (continue)"
	sudo $MERO_ROOT/utils/m0console -f 116 -s 10.0.2.15@tcp:12345:34:101 -c 10.0.2.15@tcp:12345:31:100 -d '[6:(^d|1:8,1),(^d|1:10,1),(^d|1:12,1),(^d|1:14,1),(^d|1:16,1),(^d|1:18,1)]'
	sudo $MERO_ROOT/utils/m0console -f 116 -s 10.0.2.15@tcp:12345:34:101 -c 10.0.2.15@tcp:12345:31:100 -d '[7:(^d|1:8,5),(^d|1:10,5),(^d|1:12,5),(^d|1:14,5),(^d|1:16,5),(^d|1:18,5),(^o|1:2,5)]'


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
    tag: Dynamic
    contents: []
EOF
}

main "$@"
