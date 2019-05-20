# RFC: Supporting several IO services per node

## Problem

XXX

## Solution

XXX

### Facts schema changes

Note: `%` symbol represents sequence items.  E.g., `foo/%` denotes an item of sequence `foo`.

- Server role descriptor (`id_m0_servers/%/m0h_roles/%`) changes: -- XXX-0
  - add `m0h_services` field.
- Server descriptor (`id_m0_servers/%`) changes:
  - add `m0h_services` field; -- XXX-1
  - move `m0h_devices` field to `id_m0_servers/%/m0h_services/%/`.

XXX-0: Why whould we put this into role descriptor?  Server descriptor suits better.
XXX-1: Currently only some of role descriptors ("storage" roles) have `m0h_services` field.  Shouldn't each of them have it?

### Server descriptor as per new facts schema

```
id_m0_servers:
  - m0h_fqdn: <string>
    # ... No changes apart from moving `m0h_devices` into `m0h_services`.
    m0h_roles:
      - name: <string>
    m0h_services:
      - name: <string>
        m0h_devices:
          - m0d_wwn: <string>
            m0d_serial: <string>
            m0d_bsize: <integer>
            m0d_size: <integer>
            m0d_path: <string>
            m0d_slot: <integer>
```
