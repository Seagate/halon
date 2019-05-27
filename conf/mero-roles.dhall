-- XXX <<<<<<<
let lnid = "{{ lnid }}"
let hostMemAs = 999
let hostMemRss = 999
let hostMemStack = 999
let hostMemMemlock = 999
let hostCores = [1, 1, 1]
-- XXX >>>>>>>

let U = < UNatural : Natural | UListText : List Text >  -- XXX ugly

-- https://hackage.haskell.org/package/aeson-1.4.2.0/docs/Data-Aeson-TH.html#v:defaultTaggedObject
let TaggedObject =
  { tag : Text
  , contents : U
  }

let ProcessOwnership = < Managed | Independent >

let showProcessOwnership = \(ownership : ProcessOwnership) ->
    let conv = { Managed = "Managed", Independent = "Independent" }
    in merge conv ownership : Text

let ProcessTypeClovis = { name : Text, ownership : ProcessOwnership }

let ProcessType =
  < PLM0t1fs
  | PLClovis : ProcessTypeClovis
  | PLM0d : Natural
  | PLHalon
  >

let taggedProcessType = \(procType : ProcessType) ->
    let empty = U.UListText ([] : List Text)
    let conv =
      { PLM0t1fs = { tag = "PLM0t1fs", contents = empty }
      , PLClovis = \(clovis : ProcessTypeClovis) ->
          { tag = "PLClovis"
          , contents = U.UListText
              [ clovis.name
              , showProcessOwnership clovis.ownership
              ]
          }
      , PLM0d = \(bootLevel : Natural) ->
          { tag = "PLM0d"
          , contents = U.UNatural bootLevel
          }
      , PLHalon = { tag = "PLHalon", contents = empty }
      }
    in
    merge conv procType : TaggedObject

let Process : Type =
  { m0p_endpoint : Text
  , m0p_mem_as : Natural
  , m0p_mem_rss : Natural
  , m0p_mem_stack : Natural
  , m0p_mem_memlock : Natural
  , m0p_cores : List Natural
  -- , m0p_services : List Service
  , m0p_boot_level : TaggedObject
  -- , m0p_environment :: Maybe [(String, M0ProcessEnv)]
  , m0p_multiplicity : Optional Natural
  }

let mkProcess =
    \(endpoint : Text) ->
    \(procType : ProcessType) ->
    \(multiplicity : Optional Natural) ->
  { m0p_endpoint = endpoint
  , m0p_mem_as = hostMemAs
  , m0p_mem_rss = hostMemRss
  , m0p_mem_stack = hostMemStack
  , m0p_mem_memlock = hostMemMemlock
  , m0p_cores = hostCores
  , m0p_boot_level = taggedProcessType procType
  , m0p_multiplicity = multiplicity
  } : Process

let Role : Type =
  { name : Text
  , content : List Process
  }

let mkEndpoint = \(nid : Text) -> \(portal : Natural) -> \(tmid : Natural) ->
    let show = Natural/show
    in "${nid}:12345:${show portal}:${show tmid}"

let mkRole =
    \(name : Text) ->
    \(endpoint : Text) ->
    \(procType : ProcessType) ->
    \(multiplicity : Optional Natural) ->
  { name = name
  , content = [ mkProcess endpoint procType multiplicity ]
  } : Role

let clovisApp =
    \(name : Text) ->
    \(endpoint : Text) ->
    \(ownership : ProcessOwnership) ->
    let procType = ProcessType.PLClovis { name = name, ownership = ownership}
    in mkRole name endpoint procType (Some 4) : Role

let ep = mkEndpoint lnid
let none = None Natural

in
  [ mkRole "ha" (ep 34 101) ProcessType.PLHalon none
  , mkRole "confd" (ep 44 101) (ProcessType.PLM0d 0) none
  , mkRole "mds" (ep 41 201) (ProcessType.PLM0d 1) none
  , mkRole "storage" (ep 41 401) (ProcessType.PLM0d 1) none
  , mkRole "m0t1fs" (ep 41 301) ProcessType.PLM0t1fs none
  , clovisApp "clovis-app" (ep 41 302) ProcessOwnership.Independent
  , clovisApp "s3server" (ep 41 303) ProcessOwnership.Managed
  ]
