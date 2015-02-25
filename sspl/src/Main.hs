-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Generate bindings.

{-# LANGUAGE OverloadedStrings #-}

import SSPL.Schema (monitorResponse)

import Data.Aeson.Schema
import Data.Aeson.Schema.CodeGen

import qualified Data.Map as M
import qualified Data.Text.IO as T

import Language.Haskell.TH

main :: IO ()
main = let
    graph = M.singleton "MonitorResponse" monitorResponse
  in do
    (code, _) <- runQ $ generateModule "SSPL.Bindings" graph
    T.writeFile "src/SSPL/Bindings.hs" code
