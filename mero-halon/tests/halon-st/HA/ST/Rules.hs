-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Entry point for halon-st.
--
-- When adding new rules/tests, see "HA.ST.Rules"
module HA.ST.Rules where

import           HA.RecoveryCoordinator.Actions.Core (LoopState)
import qualified HA.ST.ClusterRunning
import           HA.ST.Common
import qualified HA.ST.ProcessKeepalive
import           Network.CEP (Definitions)

-- | List of tests to expose to the user. Add new tests here.
tests :: [HASTTest]
tests =
  [ HA.ST.ClusterRunning.test
  , HA.ST.ProcessKeepalive.test
  ]

-- | Rules that are potentially used by more than one test. If a test
-- defines its own rules that no other tests rely on, add it to its
-- '_st_rules' instead.
sharedRules :: [Definitions LoopState ()]
sharedRules = []

rules :: Definitions LoopState ()
rules = sequence_ $ concatMap _st_rules tests ++ sharedRules
