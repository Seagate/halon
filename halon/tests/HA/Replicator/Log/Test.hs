-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- A provisional log implementation for testing

{-# LANGUAGE TypeFamilies #-}
module HA.Replicator.Log.Test ( TestLog, getLog ) where

import HA.Replicator.Log ( Log(..), Slot )

import Control.Distributed.Process ( Process, liftIO )

import Data.IORef ( newIORef, atomicModifyIORef, readIORef, IORef )


-- | A provisional log implementation for testing.
newtype TestLog a = TestLog (IORef (Slot,[a]))

-- | Provisional function to obtain a log.
getLog :: Process (TestLog a)
getLog = liftIO $ fmap TestLog $ newIORef (0,[])

instance Log (TestLog a) where

  type Entry (TestLog a) = a

  readFrom (TestLog r) s = liftIO $ readIORef r >>= \(first,entries) ->
    return $ if first > s
               then Nothing
               else Just$ reverse $ take (length entries-(s-first)) entries

  write (TestLog r) e =
    liftIO $ atomicModifyIORef r $ \(first,entries) -> ((first,e:entries),())
