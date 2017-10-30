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

import Control.Monad (mapM_)
import Data.List (isPrefixOf)
import Data.Maybe (maybeToList)

data OutputRaw = OutputRaw
data OutputDOT = OutputDOT

class Repr a where
    header :: a -> Maybe String
    line :: a -> (String, String, String) -> String
    footer :: a -> Maybe String

instance Repr OutputRaw where
    header _ = Nothing
    line _ (rel, a, b) = unwords $ map shorten [a, rel, b]
    footer _ = Nothing

instance Repr OutputDOT where
    header _ = Just "digraph RG {"
    line _ (rel, a, b) = unwords $ [ "    \"" ++ shorten a ++ "\""
                                   , "->"
                                   , "\"" ++ shorten b ++ "\""
                                   , "[label=\"" ++ shorten rel ++ "\"]"
                                   ]
    footer _ = Just "}"

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
main = let fmt = OutputDOT
       in mapM_ putStrLn $ concat [ maybeToList (header fmt)
                                  , map (line fmt) $(resources ''Relation)
                                  , maybeToList (footer fmt)
                                  ]
