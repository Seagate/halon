{--
(remove-hook 'after-change-functions 'dhall-after-change)
(setq-local indent-tabs-mode nil)
(setq dhall-use-header-line nil)
(setq dhall-format-at-save nil)
--}

let cmu = "cmu.local"  -- Facter.value(:hostname)

let defaultPool : ./Pool.dhall =
  { name = "default"
  , disks = [ { host = cmu, filter = "" } ]
  , dataUnits = 8
  , parityUnits = 2
  , allowedFailures = None ./Failures.dhall
  }

let confSinglenode : ./MiniConf.dhall =
  { ssus = [ { host = cmu, disks = "" } ]
  , pools = [ defaultPool ]
  , confds = [ cmu ]
  , clovisApps = [ cmu ]
  }

in confSinglenode

-- let mkSite = \(idx : Natural) ->
--   { site_idx = idx
--   , site_racks = [] : List Text
--   }
-- in
-- { id_sites = [ mkSite 0 ] }
