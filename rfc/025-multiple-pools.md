# RFC: Multiple pools

## Introduction

Current version of Halon can generate cluster configurations with only
one filesystem object and up to three pools (MD, IO and, optionally,
CAS).  This RFC documents the changes needed to support configurations
with arbitrary number of filesystems and pools per filesystem.

## Deliverables

### Phase 1

Multiple profiles, one pool per profile. (Note that there is
one-to-one relation between profile and filesystem.)

This requires new schema of `halon_facts.yaml` file and modification
of Halon code.  No Mero code changes are necessary.

### Phase 2

Multiple pools per profile.

This requires changes of both Halon and Mero code.

## halon_facts.yaml

Halon obtains cluster configuration data from `halon_facts.yaml` file.
Current schema of the facts file does not include pool information.
Halon thinks this info up, assigning all of the disks to the only IO
pool.

In order to support multiple pools, we need to modify the schema of
facts file.  New schema contains pools specification and tags each
disk with the id of pool it belongs to.

### Facts schema changes

(Here we use `%` symbol to represent sequence items; `foo/%` denotes
an item of sequence `foo`.)

- Add top-level `profiles` section --- list of profile descriptors
  (see [New facts schema](#new-facts-schema) below).
- Rename `id_m0_servers` to `nodes`, `id_racks` to `racks`.
- Node descriptor (`nodes/%`) changes:
  - use `n_` prefix for the fields (this will require updating of
    "mero\_role\_mappings");
  - delete `n_mem_{as,rss,stack,memlock}` and `n_cores` fields
    (rationale: Halon can deduce these values from
    `racks/%/rack_enclosures/%/enc_hosts/%/h_{memsize,cpucount}`);
  - move disks specification (formerly accessible via
    `id_m0_servers/%/m0h_devices`) to `h_disks` field of host descriptors
    (`racks/%/rack_enclosures/%/enc_hosts/%/h_disks`);
  - rename `n_roles` to `n_mero_roles` and rename its `name` field to
    `mr_name`.
- Host descriptor (`racks/%/rack_enclosures/%/enc_hosts/%`) changes:
  - move `h_halon/address` to `h_halon_address`;
  - move `h_halon/roles` to `h_halon_roles` and rename its `name` field
    to `hr_name`;
  - `h_halon` is empty now --- delete it.
- Disk descriptor (`racks/%/rack_enclosures/%/enc_hosts/%/h_disks/%`)
  changes:
  - substitute `m0d_` prefix with `d_`;
  - add `d_pool` attribute --- a string, equal to
    `profiles/%/prof_pools/%/pool_id` of the pool which this disk
    belongs to.
- Drop `id_m0_globals` section.  Some of its settings (`pdclust_attr` and
  `failure_set_gen`) are moved to `profiles/%/prof_pools/%`, the rest are
  not used.

### New facts schema

```
profiles:
  - prof_id: <string>  # Unique name of profile.
    prof_md_redundancy: <integer>  # Meta-data redundancy (`m0_conf_filesystem::cf_redundancy` in Mero).
    prof_pools:
      - pool_id: <string>  # Unique name of pool.
        pool_pdclust_attr: # Parity de-clustering attributes.
          pa_unit_size: <integer>  # Stripe unit size (`m0_pdclust_attr::pa_unit_size` in Mero).
          pa_N: <integer>  # Number of data units in a parity group (`m0_pdclust_attr::pa_N` in Mero).
          pa_K: <integer>  # Number of parity units in a parity group (`m0_pdclust_attr::pa_K` in Mero).
          pa_seed: [<integer>, <integer>]  # Seed for tile column permutations generator (`m0_pdclust_attr::pa_seed` in Mero).
        pool_failure_set_gen:
          tag: Formulaic  # Supported values: `Formulaic`, `Preloaded`.
          contents:       # see Note-1
            - [<integer>, <integer>, <integer>, <integer>, <integer>]
        pool_ver_policy: <integer>  # Pool version selection policy (`m0_conf_pool::pl_pver_policy` in Mero).
racks:
  - rack_idx: <integer>
    rack_enclosures:
      - enc_idx: <integer>
        enc_id: <string>
        enc_bmc:
          - bmc_addr: <string>
            bmc_user: <string>
            bmc_pass: <string>
        enc_hosts:
          - h_fqdn: <string>
            h_memsize: <float>
            h_cpucount: <integer>
            h_interfaces:
              - if_macAddress: <string>
                if_network: <string>
                if_ipAddrs: [<string>]
            h_disks:
              - d_wwn: <string>
                d_serial: <string>
                d_bsize: <integer>
                d_size: <integer>
                d_path: <string>
                d_slot: <integer>
                d_pool: <string>  # = `profiles/%/prof_pools/%/pool_id`
            h_halon_address: <string>
            h_halon_roles:
              - hr_name: <string>  # Reference to an item in "halon\_role\_mappings".
nodes:
  - n_fqdn: <string>  # = `racks/%/rack_enclosures/%/enc_hosts/%/h_fqdn`
    n_lnid: <string>
    n_mero_roles:
      - mr_name: <string>  # Reference to an item in "mero\_role\_mappings".
```

#### Note-1:

If tag == `Preloaded`, then contents is a list of 3 integers:

- number of disk failures to tolerate;
- number of controller failures to tolerate;
- number of disk failures equivalent to controller failure.

Otherwise (tag == `Formulaic`), contents is a list of _allowance
vectors_ for formulaic pool versions.  Each allowance vector
(`m0_conf_pver_formulaic::pvf_allowance` in Mero) is an array of
`M0_CONF_PVER_HEIGHT` (5) integers:

- 0;
- number of failed racks;
- number of failed enclosures;
- number of failed controllers;
- number of failed disks.
