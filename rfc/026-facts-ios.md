# RFC: Supporting several IO services per node

## Problem

Presently Halon is not able to start multiple storage (IOS) m0d processes on a single host.  This feature is required as part of the HA failover task in the "EOS" product (aka single PODS solution).  Current Halon facts file format allows at most one storage role per host.

It is also required to associate drives with services that will use them, e.g. IOS, ADDB, and BE.  This is not supported by the present facts file format.

## Solution

1. Modify facts file format to allow specification of server/process/service/device hierarchy.
2. Abolish "Mero roles" file.  `/etc/halon/role_maps/` directory and `/etc/halon/mero_role_mappings` symlink should not be created any more.

### Facts schema changes

Notation: `%` symbol represents sequence items, e.g., `foo/%` denotes an item of sequence `foo`.

- Server descriptor (`id_m0_servers/%`) changes:
  - add `m0h_processes` section;
  - for each mero role (`m0h_roles/%/name`):
    - create new `m0h_processes/%` entry --- a process descriptor;
    - copy `%/content` of the corresponding mero role into the newly created process descriptor.
  - delete `m0h_roles` section;
  - distribute devices (`m0h_devices/%`) among services (`m0h_processes/%/m0p_services/%/m0s_devices`).
- Process descriptor (`id_m0_servers/%/m0h_processes/%`): rename `m0p_boot_level` to `m0p_type`.

### New facts schema

```
id_sites: ...  # no changes
id_m0_servers:
  - m0h_fqdn: <string>
    ...  # `host_mem_*`, `host_cores`, and `lnid` fields
    m0h_processes:
      - m0p_endpoint: <string>
        ...  # `m0p_endpoint`, `m0p_mem_*`, and `m0p_cores` fields
        m0p_type:
          tag: <string>  # e.g., PLM0d
          contents: <...>  # depends on `m0p_type`
        m0p_services:
          - m0s_type:
              tag: <string>  # e.g., CST_IOS
              contents: []
            m0s_endpoints: [<string>]
            m0s_devices:
              - m0d_wwn: <string>
                m0d_serial: <string>
                m0d_path: <string>
                m0d_bsize: <integer>
                m0d_size: <integer>
                m0d_slot: <integer>
id_m0_globals: ...  # no changes
id_pools: ...  # no changes
id_profiles: ...  # no changes
```
