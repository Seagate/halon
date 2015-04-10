-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- An implementation of 'AcceptorStore'

module Control.Distributed.Log.Persistence.Paxos where

import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Log.Persistence as P
import Data.Binary (encode, decode)
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
    tref <- P.lookup pv 1 >>= newIORef . fmap decode
    return AcceptorStore
      { storeInsert = \d v -> do
          modifyIORef mref $ Map.insert d v
          P.atomically ps [ P.Insert pm (dToPair d) v ]
      , storeLookup = \d -> do
          mt <- readIORef tref
          if Just d <= mt then return $ Left True
          else do
            m <- readIORef mref
            return $ maybe (Left False) Right $ Map.lookup d m
      , storeTrim = \d -> do
          m <- readIORef mref
          let (olds, mv, m') = Map.splitLookup d m
          writeIORef mref $ maybe id (Map.insert d) mv m'
          writeIORef tref $ Just d
          P.atomically ps [ P.Trim pm $ map dToPair $ Map.keys olds
                          , P.Insert pv (1 :: Int) (encode d)
                          ]
      , storePut = \v -> do
          writeIORef vref $ Just v
          P.atomically ps [ P.Insert pv (0 :: Int) v ]
      , storeGet = readIORef vref
      , storeClose = P.close ps
      }
