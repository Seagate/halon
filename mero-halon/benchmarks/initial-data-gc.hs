{-# LANGUAGE CPP                       #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE TemplateHaskell           #-}
{-# OPTIONS_GHC -fno-warn-orphans      #-}
{-# OPTIONS_GHC -fno-warn-unused-binds #-}

-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Goes through 'InitialData' load procedure and times garbage collect
-- on the resulting graph.

import Control.DeepSeq (NFData(rnf))
import Control.Exception as E
import Criterion.Main
import HA.Castor.Tests (loadInitialData)
import HA.ResourceGraph (Graph, getGraphResources, garbageCollectRoot)
import Network.BSD (getHostname)
import Mero (withM0)
import Network.Transport (Transport(..))
import Network.Transport.InMemory (createTransport)
import Test.Framework (withTmpDirectory)

instance NFData Graph where
  -- Good enough for GC?
  rnf g = let gr = getGraphResources g
              l = length gr
              l' = concatMap snd gr
          in l `seq` l' `seq` ()

main :: IO ()
main = defaultMain [
    env loadInitialDataGraph $ \g ->
      bench "initial-data-gc" $ nf garbageCollectRoot g
  ]

-- | Run 'loadInitialData' and retrieve the resulting graph.
loadInitialDataGraph :: IO Graph
loadInitialDataGraph = E.bracket createTransport closeTransport $ \t ->
  withTmpDirectory $ withM0 $ loadInitialData getHostname t
