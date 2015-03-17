-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- An implementation of 'AcceptorStore'

module Control.Distributed.Log.Persistence.Paxos where

import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Log.Persistence as P
import Data.IORef
import qualified Data.Map as Map
import Data.String


acceptorStore :: PersistentStore -> IO AcceptorStore
acceptorStore ps = do
    let dToPair (DecreeId l dn) = (fromEnum l, dn)
        pairToD (l, dn)         = DecreeId (toEnum l) dn
    pm <- P.getMap ps $ fromString "decrees"
    pv <- P.getMap ps $ fromString "values"
    mref <- P.pairsOfMap pm >>=
              newIORef .  Map.fromList .  map (\(k, v) -> (pairToD k, v))
    vref <- P.lookup pv 0 >>= newIORef
    return AcceptorStore
      { storeInsert = \d v -> do
          modifyIORef mref $ Map.insert d v
          P.atomically ps [ P.Insert pm (dToPair d) v ]
      , storeLookup = \d -> fmap (Map.lookup d) $ readIORef mref
      , storePut = \v -> do
          writeIORef vref $ Just v
          P.atomically ps [ P.Insert pv (0 :: Int) v ]
      , storeGet = readIORef vref
      , storeClose = P.close ps
      }
