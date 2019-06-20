-- -*- outline-regexp: "-- #+" -*-

-- # TODO
--   * Q: How many racks?
--     A: m0genfacts creates only one rack with rack_idx=1.

-- \(TODO : forall (a : Type) -> a) ->

-- # ClusterConfig et al.
let List/map = https://raw.githubusercontent.com/dhall-lang/dhall-lang/master/Prelude/List/map

let HostName = Text
let GlobPattern = Text
let Regexp = Text

let FailureVec =
  { site : Natural
  , rack : Natural
  , encl : Natural
  , ctrl : Natural
  , disk : Natural
  }

-- [KN] Pool with 'name' field is needed in ClusterConfig only.
-- id_pools requires a pool with 'id' field instead.
let Pool =
  { name : Text
  , disks : List { host : HostName, filter : Optional Regexp }
  , data_units : Natural
  , parity_units : Natural
  , allowed_failures : FailureVec
  }

-- XXX Is this needed?
let ClusterConfig =
  { clients : Optional (List HostName)
  , clovis_apps : Optional (List HostName)
  , s3servers : Optional (List HostName)
  , confds : List HostName
  , ssus : List { host : HostName, disks : GlobPattern }
  , pools : Optional (List Pool)
  }

let IdPool =
  { pool_id : Text
  , pool_pdclust_attrs :
    { data_units : Natural
    , parity_units : Natural
    , unit_size : Natural
    , seed : List Natural
    }
  , pool_allowed_failures : List FailureVec
  }

-- XXX should be specified explicitly. Double check the expected type
let m0_block_size : Natural = 1024

-- XXX double check that this conversion is valid in general
let toIdPool : Pool -> IdPool = \(p : Pool) ->
  { pool_id = p.name
  , pool_pdclust_attrs =
    { data_units = p.data_units
    , parity_units = p.parity_units
    , unit_size = m0_block_size
    , seed = [101, 102]
    }
  , pool_allowed_failures = [ p.allowed_failures ]
  }

-- # types

let IPv4 = { a : Natural, b : Natural, c : Natural, d : Natural }

let IPv4/show = \(ip : IPv4) ->
    let show = Natural/show
    in "${show ip.a}.${show ip.b}.${show ip.c}.${show ip.d}"

let Bmc = { bmc_addr : Text, bmc_user : Text, bmc_pass : Text }

let Memory =
  { as : Natural
  , rss : Natural
  , stack : Natural
  , memlock : Natural
  }

let Host =
  { fqdn : Text
  , memsize : Natural
  , cpucount : Natural
  , halon_address : { ip : IPv4, port : Natural }
  , halon_roles : List Text
  }

-- XXX Merge `Server` with `Host`?
let Server =
  { fqdn : Text
  , memory : Memory
  , nr_cores : Natural
  , lnid : { ip : IPv4, transport : Text }
  }

let Enclosure =
  { enc_idx : Natural
  , enc_id : Text
  , enc_bmc : List Bmc
  -- , enc_hosts : List Host
  }

let mkEnclosure : Natural -> Enclosure =
    \(idx : Natural) ->
    let bmc = { bmc_addr = IPv4/show { a = 0, b = 0, c = 0, d = 0 }
              , bmc_user = "admin"
              , bmc_pass = "admin"
              }
    in
      { enc_idx = idx
      , enc_id = "ENC#" ++ Natural/show idx
      , enc_bmc = [ bmc, bmc ]
      -- , enc_hosts = TODO (List Host)
      }

let Rack =
  { rack_idx : Natural
  , rack_enclosures : List Enclosure
  }

let Site =
  { site_idx : Natural
  , site_racks : List Rack
  }

-- # and - finally - the facts.  Ta-da!
----------------------------------------------------------------------

let enclosures : List Enclosure =
  [ mkEnclosure 0
  ]

let PoolName = Text

let Profile =
  { prof_id : Text
  , prof_pools: List PoolName
  }


let mkProfile : List Pool -> Profile =
  \(pools : List Pool) ->
    let name : Pool -> PoolName = \(p : Pool) -> p.name
    let names = List/map Pool PoolName name pools
    in {
      prof_id = "prof_id",
      prof_pools = names
    }


let rack : Rack = { rack_idx = 0, rack_enclosures = enclosures }
let site : Site = { site_idx = 0, site_racks = [rack] }

let fakePool : Text -> Pool = \(name: Text) ->
  { name = name
  , disks = [{host = "localhost", filter = Some ".*" }]
  , data_units = 1
  , parity_units = 0
  , allowed_failures =
    { site = 1
    , rack = 0
    , encl = 0
    , ctrl = 0
    , disk = 0
    }
  }

let pools = [ fakePool "test-1", fakePool "test-2" ]
let id_pools : List Pool -> List IdPool = \(p : List Pool) -> List/map Pool IdPool toIdPool p
let id_profiles : List Profile = [ mkProfile pools ]

in
  { id_sites = [site]
  -- , id_m0_servers = [TODO Server]
  -- XXX COMPLETEME
  -- , id_m0_globals
  , id_pools = id_pools pools
  , id_profiles = id_profiles
  }
