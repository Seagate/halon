-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- An implementation of 'AcceptorStore'

module Control.Distributed.Log.Persistence.Paxos where

import Control.Distributed.Process hiding (finally)
import Control.Distributed.Process.Consensus
import Control.Distributed.Process.Consensus.Paxos
import Control.Distributed.Process.Pool.Bounded
import Control.Distributed.Log.Persistence as P
import Control.Monad
import Control.Monad.Catch
import Data.IORef
import qualified Data.Map as Map
import Data.Maybe
import qualified Data.Set as Set
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
    -- @procsRef@ is @Just procs@ while the store is not closed. @procs@ is
    -- the set of all running async processes.
    procsRef <- newIORef $ Just Set.empty
    pool <- newProcessPool 50
    let doAsync task = do
          mproc <- submitTask pool task
          case mproc of
            Nothing -> return ()
            Just proc -> void $ spawnLocal $ do
               self <- getSelfPid
               let forceMaybe = maybe Nothing (Just $!)
               ok <- liftIO $ atomicModifyIORef' procsRef $ \mprocs ->
                 (forceMaybe $ Set.insert self <$> mprocs, isJust mprocs)
               when ok $
                  proc `finally`
                   liftIO (atomicModifyIORef' procsRef $ \mprocs ->
                                   (forceMaybe $ Set.delete self <$> mprocs, ())
                        )
    return AcceptorStore
      { storeInsert = \dvs done ->
          doAsync $ {-# SCC "acceptorStore/storeInsert" #-} do
            liftIO $ do
              modifyIORef' mref $ \m -> foldr (uncurry Map.insert) m dvs
              P.atomically ps $ map (\(d, v) -> P.Insert pm (dToPair d) v) dvs
            done
      , storeLookup = \d done ->
          doAsync $ {-# SCC "acceptorStore/storeLookup" #-}
                    liftIO (Map.lookup d <$> readIORef mref) >>= done
      , storeTrim = \d -> doAsync $ {-# SCC "acceptorStore/storeTrim" #-}
          liftIO $ do
            m <- readIORef mref
            let (olds, mv, m') = Map.splitLookup d m
            writeIORef mref $ maybe id (Map.insert d) mv m'
            P.atomically ps [ P.Trim pm $ map dToPair $ Map.keys olds ]
      , storeList = \done ->
          doAsync $ liftIO (Map.assocs <$> readIORef mref) >>= done
      , storeMap = \done ->
          doAsync $ liftIO (readIORef mref) >>= done
      , storePut = \v done -> doAsync $ {-# SCC "acceptorStore/storePut" #-} do
          liftIO $ do
            writeIORef vref $ Just v
            P.atomically ps [ P.Insert pv (0 :: Int) v ]
          done
      , storeGet = \done -> doAsync $ liftIO (readIORef vref) >>= done
      , storeClose = callLocal $ do
          mprocs <- liftIO $ atomicModifyIORef procsRef $ \mprocs ->
                                                            (Nothing, mprocs)
          case mprocs of
            Nothing -> return ()
            Just procs -> do
              mapM_ monitor procs
              mapM_ (`kill` "storeClose") procs
              replicateM_ (Set.size procs)
                          (expect :: Process ProcessMonitorNotification)
          liftIO $ P.close ps
      }
