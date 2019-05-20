{ ssus : List
    { host : Text
    , disks : Text  -- [optional] glob pattern
    }
, pools : List ./Pool.dhall
, confds : List Text
, clovisApps : List Text
}
