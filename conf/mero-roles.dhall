let List/map = https://raw.githubusercontent.com/dhall-lang/dhall-lang/master/Prelude/List/map

let List/replicate = https://raw.githubusercontent.com/dhall-lang/dhall-lang/master/Prelude/List/replicate

let Optional/map = https://raw.githubusercontent.com/dhall-lang/dhall-lang/master/Prelude/Optional/map

-- XXX <<<<<<<
let lnid = "{{ lnid }}"
let hostMemAs = 999
let hostMemRss = 999
let hostMemStack = 999
let hostMemMemlock = 999
let hostNumberOfCores = 3
-- XXX >>>>>>>

let Union =
  < UNatural : Natural
  | UListNatural : List Natural
  | UText : Text
  | UListText : List Text
  >

let emptyUListText = Union.UListText ([] : List Text)

-- https://hackage.haskell.org/package/aeson-1.4.2.0/docs/Data-Aeson-TH.html#v:defaultTaggedObject
let TaggedObject = { tag : Text, contents : Union }

let mkTagged = \(tag : Text) -> \(contents : Union) ->
    { tag = tag, contents = contents } : TaggedObject

let Range = { from : Natural, to : Natural }

let M0ProcessEnv = < M0PEnvValue : Text | M0PEnvRange : Range >

let reprM0ProcessEnv : M0ProcessEnv -> TaggedObject =
    \(x : M0ProcessEnv) ->
    let conv =
      { M0PEnvValue = \(val : Text) ->
          mkTagged "M0PEnvValue" (Union.UText val)
      , M0PEnvRange = \(range : Range) ->
          mkTagged "M0PEnvRange" (Union.UListNatural [range.from, range.to])
      }
    in merge conv x

let EnvVar = { key : Text, val : M0ProcessEnv }

let UEnv = < UEnvKey : Text | UEnvVal : TaggedObject >

let renderEnvVar : EnvVar -> List UEnv =
    \(x : EnvVar) ->
    [ UEnv.UEnvKey x.key, UEnv.UEnvVal (reprM0ProcessEnv x.val) ]

let Endpoint = { nid : Text, portal : Natural, tmid : Natural }

let showEndpoint = \(ep : Endpoint) ->
    let show = Natural/show
    in "${ep.nid}:12345:${show ep.portal}:${show ep.tmid}"

let ProcessOwnership = < Managed | Independent >

let showProcessOwnership : ProcessOwnership -> Text =
    \(x : ProcessOwnership) ->
    let conv = { Managed = "Managed", Independent = "Independent" }
    in merge conv x

let ProcessTypeClovis = { name : Text, ownership : ProcessOwnership }

let ProcessType =
  < PLM0t1fs
  | PLClovis : ProcessTypeClovis
  | PLM0d : Natural
  | PLHalon
  >

let reprProcessType : ProcessType -> TaggedObject =
    \(x : ProcessType) ->
    let conv =
      { PLM0t1fs = mkTagged "PLM0t1fs" emptyUListText
      , PLClovis = \(clovis : ProcessTypeClovis) ->
            let params = [ clovis.name, showProcessOwnership clovis.ownership ]
            in mkTagged "PLClovis" (Union.UListText params)
      , PLM0d = \(bootLevel : Natural) ->
            mkTagged "PLM0d" (Union.UNatural bootLevel)
      , PLHalon = mkTagged "PLHalon" emptyUListText
      }
    in merge conv x

let ServiceType =
  < CST_MDS
  | CST_IOS
  | CST_CONFD
  | CST_RMS
  | CST_STATS
  | CST_HA
  | CST_SSS
  | CST_SNS_REP
  | CST_SNS_REB
  | CST_ADDB2
  | CST_CAS
  | CST_DIX_REP
  | CST_DIX_REB
  | CST_DS1
  | CST_DS2
  | CST_FIS
  | CST_FDMI
  | CST_BE
  | CST_M0T1FS
  | CST_CLOVIS
  | CST_ISCS
  >

let showServiceType : ServiceType -> Text =
    \(x : ServiceType) ->
    let conv =
      { CST_MDS     = "CST_MDS"
      , CST_IOS     = "CST_IOS"
      , CST_CONFD   = "CST_CONFD"
      , CST_RMS     = "CST_RMS"
      , CST_STATS   = "CST_STATS"
      , CST_HA      = "CST_HA"
      , CST_SSS     = "CST_SSS"
      , CST_SNS_REP = "CST_SNS_REP"
      , CST_SNS_REB = "CST_SNS_REB"
      , CST_ADDB2   = "CST_ADDB2"
      , CST_CAS     = "CST_CAS"
      , CST_DIX_REP = "CST_DIX_REP"
      , CST_DIX_REB = "CST_DIX_REB"
      , CST_DS1     = "CST_DS1"
      , CST_DS2     = "CST_DS2"
      , CST_FIS     = "CST_FIS"
      , CST_FDMI    = "CST_FDMI"
      , CST_BE      = "CST_BE"
      , CST_M0T1FS  = "CST_M0T1FS"
      , CST_CLOVIS  = "CST_CLOVIS"
      , CST_ISCS    = "CST_ISCS"
      }
    in merge conv x

let Service = { m0s_type : TaggedObject, m0s_endpoints : List Text }

let mkService =
    \(endpoint : Text) ->
    \(svcType : ServiceType) ->
  { m0s_type = mkTagged (showServiceType svcType) emptyUListText
  , m0s_endpoints = [endpoint]
  } : Service

let Process =
  { m0p_endpoint : Text
  , m0p_mem_as : Natural
  , m0p_mem_rss : Natural
  , m0p_mem_stack : Natural
  , m0p_mem_memlock : Natural
  , m0p_cores : List Natural
  , m0p_services : List Service
  , m0p_boot_level : TaggedObject
  , m0p_environment : Optional (List (List UEnv))
  , m0p_multiplicity : Optional Natural
  }

let mkProcess =
    \(endpoint : Text) ->
    \(procType : ProcessType) ->
    \(multiplicity : Optional Natural) ->
    \(services : List Service) ->
    \(env : Optional (List EnvVar)) ->
  { m0p_endpoint = endpoint
  , m0p_mem_as = hostMemAs
  , m0p_mem_rss = hostMemRss
  , m0p_mem_stack = hostMemStack
  , m0p_mem_memlock = hostMemMemlock
  , m0p_cores = List/replicate hostNumberOfCores Natural 1
  , m0p_services = services
  , m0p_boot_level = reprProcessType procType
  , m0p_environment =
        let f = List/map EnvVar (List UEnv) renderEnvVar
        in Optional/map (List EnvVar) (List (List UEnv)) f env
  , m0p_multiplicity = multiplicity
  } : Process

let Role = { name : Text, content : List Process }

let mkRole =
    \(name : Text) ->
    \(endpoint : Text) ->
    \(procType : ProcessType) ->
    \(multiplicity : Optional Natural) ->
    \(svcTypes : List ServiceType) ->
    \(env : Optional (List EnvVar)) ->
    let services = List/map ServiceType Service (mkService endpoint) svcTypes
    in
    { name = name
    , content = [ mkProcess endpoint procType multiplicity services env ]
    } : Role

let clovisApp =
    \(name : Text) ->
    \(endpoint : Text) ->
    \(ownership : ProcessOwnership) ->
    \(env : Optional (List EnvVar)) ->
    let procType = ProcessType.PLClovis { name = name, ownership = ownership}
    in mkRole name endpoint procType (Some 4) [ServiceType.CST_RMS] env : Role

let ep : Natural -> Natural -> Text =
    \(portal : Natural) ->
    \(tmid : Natural) ->
    showEndpoint { nid = lnid, portal = portal, tmid = tmid }

let none = None Natural
let noEnv = None (List EnvVar)
let rms = ServiceType.CST_RMS

in
  [ mkRole "ha" (ep 34 101) ProcessType.PLHalon none
      [ServiceType.CST_HA, rms] noEnv
  , mkRole "confd" (ep 44 101) (ProcessType.PLM0d 0) none
      [ServiceType.CST_CONFD, rms] noEnv
  , mkRole "mds" (ep 41 201) (ProcessType.PLM0d 1) none
      [rms, ServiceType.CST_MDS, ServiceType.CST_ADDB2] noEnv
  , mkRole "storage" (ep 41 401) (ProcessType.PLM0d 1) none
      [ rms
      , ServiceType.CST_IOS
      , ServiceType.CST_SNS_REP
      , ServiceType.CST_SNS_REB
      , ServiceType.CST_ADDB2
      , ServiceType.CST_CAS
      , ServiceType.CST_ISCS
      ]
      noEnv
  , mkRole "m0t1fs" (ep 41 301) ProcessType.PLM0t1fs none [rms] noEnv
  , clovisApp "clovis-app" (ep 41 302) ProcessOwnership.Independent noEnv
  , let env = { key = "MERO_S3SERVER_PORT"
              , val = M0ProcessEnv.M0PEnvRange { from = 8081, to = 8099 }
              }
    in clovisApp "s3server" (ep 41 303) ProcessOwnership.Managed (Some [env])
  ]
