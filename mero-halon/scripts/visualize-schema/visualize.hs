{-# OPTIONS_GHC -Wall -Werror #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- Import all modules from Halon and Mero-Halon:
import HA.RecoveryCoordinator.CEP ()
import HA.RecoveryCoordinator.Castor.Rules ()
import HA.RecoveryCoordinator.Definitions ()
import HA.RecoveryCoordinator.Mero ()
import HA.RecoveryCoordinator.Service.Rules ()
import HA.Resources.Castor ()
import HA.Resources.Castor.Initial ()
import HA.Services.DecisionLog ()
import HA.Services.SSPL ()
import HA.Services.SSPLHL ()
import Mero.Messages ()
import Mero.RemoteTables ()
------------------------------------------------

import HA.ResourceGraph (Cardinality(AtMostOne,Unbounded), Relation)
import TH (RelationInfo(..), resources, sep)
import Data.List (intersperse, isPrefixOf)

data Fmt = FmtRaw | FmtDot

header :: Fmt -> [String]
header FmtDot = ["digraph ResourceGraphSchema {"]
header _ = []

footer :: Fmt -> [String]
footer FmtDot = ["}"]
footer _ = []

repr :: Fmt -> [RelationInfo] -> String
repr fmt rs = let doc = header fmt ++ map (repr1 fmt) rs ++ footer fmt
              in concat . intersperse "\n" $ doc

repr1 :: Fmt -> RelationInfo -> String
repr1 FmtRaw RelationInfo{..} = unwords $
    map shorten [riFrom, riBy, riTo] ++ map show [riCardFrom, riCardTo]
repr1 FmtDot RelationInfo{..} =
    let arrHead = case riCardTo of
            AtMostOne -> "" -- defaults to ", arrowhead=normal"
            Unbounded -> ", arrowhead=onormal"
        (arrTail, dir) = case riCardFrom of
            AtMostOne -> ("", "")
            Unbounded -> (", arrowtail=oinv", ", dir=both")
    in unwords $ [ "    \"" ++ shorten riFrom ++ "\""
                 , "->"
                 , "\"" ++ shorten riTo ++ "\""
                 , "[label=\"" ++ shorten riBy ++ "\""
                   ++ concat [arrHead, arrTail, dir] ++ "]"
                 ]

shorten :: String -> String
shorten str = case break (== sep) str of
    (a, "") -> shorten' a
    (a, _:b) -> shorten' a ++ sep : shorten' b

shorten' :: String -> String
shorten' = reprefix [ ("HA.Service.Internal", "SvcI")
                    , ("HA.Services",         "Svcs")
                    , ("HA.Resources.Castor", "Cas")
                    , ("HA.Resources.Mero",   "M0")
                    , ("HA.Resources.RC",     "RC")
                    , ("HA.Resources",        "R")
                    ]
  where
    reprefix [] str = str
    reprefix ((prefix, subst):rest) str
      | (prefix ++ ".") `isPrefixOf` str = subst ++ drop (length prefix) str
      | otherwise = reprefix rest str

main :: IO ()
main = putStrLn $ repr FmtDot $(resources ''Relation)
