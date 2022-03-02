-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- An implementation of the persistence interface with LevelDB.
--

{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
module Control.Distributed.Log.Persistence.LevelDB where

import Control.Distributed.Log.Persistence as P

import Control.Arrow ((***))
import Control.Monad (liftM2)
import Data.Binary (encode, decode, Binary(..), Put, Get)
import Data.Binary.Get (getWord64be)
import Data.Binary.Put (putWord64be)
import Data.ByteString.Lazy as BS
import qualified Data.ByteString as SBS
import qualified Data.ByteString.Lazy.Char8 as C8
import Data.String (fromString)
import Data.Typeable
import Database.LevelDB.Base hiding (get, put)
import qualified Database.LevelDB.Base as L (get)
import Database.LevelDB.Internal (unsafeClose)
import qualified Database.LevelDB.Streaming as S
import System.Directory (createDirectoryIfMissing)

import Control.Exception (bracket_)
import Debug.Trace (traceEventIO)

newtype Key a = Key { fromKey :: a }

instance Binary (Key Int) where
  put (Key k) = putIntKey k
  get = fmap Key getIntKey

instance Binary (Key (Int, Int)) where
  put (Key (k0,k1)) = putIntKey k0 >> putIntKey k1
  get = fmap Key $ liftM2 (,) getIntKey getIntKey

-- A monotone encoding from integer order to lexicographic order on
-- bytestrings.
putIntKey :: Int -> Put
putIntKey k = put (k >= 0) >> putWord64be (fromIntegral k)

getIntKey :: Get Int
getIntKey = (get :: Get Bool) >> fmap fromIntegral getWord64be

-- | Opens an existing store or creates a new one if such exists.
openPersistentStore :: FilePath -> IO PersistentStore
openPersistentStore fp = do
    createDirectoryIfMissing True fp
    db <- open fp defaultOptions { createIfMissing = True }
    return $ PersistentStore
      { atomically = write' db defaultWriteOptions { sync = True } .
                       Prelude.concatMap translate
      , getMap = getMapImp db
      , close = unsafeClose db
      }
  where
    write' d v b = bracket_
      (traceEventIO $ "START persistentStore.write")
      (traceEventIO $ "STOP persistentStore.write")
      (write d v b)

    getMapImp :: forall k . IsKey k => DB -> ByteString -> IO (PersistentMap k)
    getMapImp db bs =
      if C8.elem '/' bs then
        error "C.D.L.P.LevelDB: '/' is not allowed in map keys."
      else
        return PersistentMap
          { mapId = bs
          , lookup = fmap (fmap fromStrict) .
                       L.get db defaultReadOptions { fillCache = False } .
                         encodeMapKey bs
          , pairsOfMap = keyToBinary (undefined :: k) $ const $ do
              let mapPrefix = toStrict $ BS.append bs $ fromString "/"
              withIter db defaultReadOptions { fillCache = False } $ \it ->
                S.foldr ((:) . (decodeMapKey bs *** fromStrict)) [] $
                  S.entrySlice
                    it
                    (S.KeyRange mapPrefix
                     (\bs' -> if mapPrefix `SBS.isPrefixOf` bs' then LT else GT)
                    )
                    S.Asc
          }

    translate :: WriteOp -> [BatchOp]
    translate (Insert m k v) = [Put (encodeMapKey (mapId m) k) (toStrict v)]
    -- XXX: There is no way to erase a range of keys other than deleting them
    -- one by one. http://code.google.com/p/leveldb/issues/detail?id=113
    translate (Trim (m :: PersistentMap k) ks) =
      keyToBinary (undefined :: k) $ const $
        Prelude.map (Del . encodeMapKey (mapId m)) ks

    encodeMapKey :: IsKey k => ByteString -> k -> SBS.ByteString
    encodeMapKey m k =
      toStrict $ BS.concat [m, fromString "/", keyToBinary k (encode . Key)]

    decodeMapKey :: Binary (Key k) => ByteString -> SBS.ByteString -> k
    decodeMapKey m = decodeKey . BS.drop (BS.length m + 1) . fromStrict

    decodeKey :: Binary (Key k) => ByteString -> k
    decodeKey bs = fromKey (decode bs)

    keyToBinary :: forall k a. IsKey k => k -> (Binary (Key k) => k -> a) -> a
    keyToBinary k f = case eqT :: Maybe (k :~: Int) of
      Just Refl -> f k
      _         -> ($ (eqT :: Maybe (k :~: (Int, Int)))) $ \(Just Refl) -> f k
