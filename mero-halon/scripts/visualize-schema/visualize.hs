{-# OPTIONS_GHC -Wall -Werror #-}
{-# LANGUAGE TemplateHaskell #-}
-- Import all modules from Halon and Mero-Halon
import HA.ResourceGraph
import Mero.Messages ()
import Mero.RemoteTables ()
import HA.Services.DecisionLog ()
import HA.Services.SSPL ()
import HA.Services.SSPLHL ()
import HA.RecoveryCoordinator.Mero ()
import HA.RecoveryCoordinator.CEP ()
import HA.RecoveryCoordinator.Definitions ()
import HA.RecoveryCoordinator.Castor.Rules ()
import HA.RecoveryCoordinator.Service.Rules ()
import HA.Resources.Castor ()
import HA.Resources.Castor.Initial ()
------------------------------------------------

import TH (resources)
import Data.List (intersperse, isPrefixOf)

data OutputFormat = OutputRaw | OutputDOT

type RelationInfo = (String, String, String) -- (rel, a, b)

header :: OutputFormat -> [String]
header OutputDOT = ["digraph ResourceGraphSchema {"]
header _ = []

footer :: OutputFormat -> [String]
footer OutputDOT = ["}"]
footer _ = []

repr :: OutputFormat -> [RelationInfo] -> String
repr fmt rs = let doc = header fmt ++ map (repr1 fmt) rs ++ footer fmt
              in concat . intersperse "\n" $ doc

repr1 :: OutputFormat -> RelationInfo -> String
repr1 OutputRaw (rel, a, b) = unwords $ map shorten [a, rel, b]
repr1 OutputDOT (rel, a, b) = unwords $ [ "    \"" ++ shorten a ++ "\""
                                        , "->"
                                        , "\"" ++ shorten b ++ "\""
                                        , "[label=\"" ++ shorten rel ++ "\"]"
                                        ]

shorten :: String -> String
shorten = reprefix [ ("HA.Service.Internal.Service_HA.Services", "SvcIH")
                   , ("HA.Service.Internal",                     "SvcI")
                   , ("HA.Services",                             "Svc")
                   , ("HA.Resources.Castor",                     "Cas")
                   , ("HA.Resources.Mero",                       "M0")
                   , ("HA.Resources.RC",                         "RC")
                   , ("HA.Resources",                            "R")
                   ]
  where
    reprefix [] str = str
    reprefix ((prefix, subst):rest) str
      | (prefix ++ ".") `isPrefixOf` str = subst ++ drop (length prefix) str
      | otherwise = reprefix rest str

main :: IO ()
main = putStrLn $ repr OutputDOT $(resources ''Relation)
