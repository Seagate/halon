{-# LANGUAGE TemplateHaskell #-}
-- Import all modules from Halon and Mero-Halon
import HA.ResourceGraph
import HA.Resources
import Mero.FakeEpoch()
import Mero.Messages()
import Mero.RemoteTables()
import HA.Network.Transport()
import HA.Services.DecisionLog()
import HA.Services.Monitor()
import HA.Services.SSPL()
import HA.Services.SSPLHL()
import HA.RecoveryCoordinator.Mero()
import HA.RecoveryCoordinator.CEP()
import HA.RecoveryCoordinator.Definitions()
import HA.RecoveryCoordinator.Castor.Rules()
import HA.RecoveryCoordinator.Service.Rules()
import HA.Resources.Castor()
import HA.Resources.Castor.Initial()
------------------------------------------------

import TH

import Language.Haskell.TH
import Control.Monad
import Data.List


$(return [])

main = do
  -- Write schema
  putStrLn "digraph schema {"
  forM $(resources ''Relation) $ \(rel, a, b) ->
    putStrLn $ unwords ["\""++a++"\"","->","\""++b++"\"","[label=\""++rel++"\"];"]
  putStrLn "}"
  -- Write all possible relations
  -- forM (nub $ map (\(a,_,_) -> a) $(resources ''Relation)) putStrLn
