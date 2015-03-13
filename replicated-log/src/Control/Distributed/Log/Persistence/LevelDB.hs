-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- An implementation of the persistence interface with LevelDB.
--

module Control.Distributed.Log.Persistence.LevelDB where

import Control.Distributed.Log.Persistence as P

import Control.Arrow ((***))
import Data.Binary (encode, decode)
import Data.ByteString.Lazy as BS
import qualified Data.ByteString as SBS
import Data.ByteString.Lazy.Char8 as C8
import Data.String (fromString)
import Database.LevelDB.Base
import Database.LevelDB.Internal (unsafeClose)
import qualified Database.LevelDB.Streaming as S
import System.Directory (createDirectoryIfMissing)


-- | Opens an existing store or creates a new one if such exists.
openPersistentStore :: FilePath -> IO PersistentStore
openPersistentStore fp = do
    createDirectoryIfMissing True fp
    db <- open fp defaultOptions { createIfMissing = True }
    return $ PersistentStore
      { atomically = \ops -> do
          mapM (translate db) ops >>=
            write db defaultWriteOptions { sync = True } . Prelude.concat
      ,  getMap = \bs ->
           if C8.elem '/' bs then
             error "C.D.L.P.LevelDB: '/' is not allowed in map keys."
           else
             return PersistentMap
               { mapId = bs
               , lookup = fmap (fmap fromStrict) .
                            get db defaultReadOptions { fillCache = False } .
                              encodeMapKey bs
               , pairsOfMap =
                   withIter db defaultReadOptions { fillCache = False } $ \it ->
                     S.foldr ((:) . (decodeMapKey bs *** fromStrict)) [] $
                       S.entrySlice
                         it
                         (S.KeyRange (encodeMapKey bs minBound)
                                     (flip compare (encodeMapKey bs maxBound))
                         )
                         S.Asc
               }
      , close = unsafeClose db
      }

  where translate :: DB -> WriteOp -> IO [BatchOp]
        translate _ (Insert m k v) =
          return [ Put (encodeMapKey (mapId m) k) (toStrict v) ]
        -- There is no way to erase a range of keys other than deleting them one
        -- by one. http://code.google.com/p/leveldb/issues/detail?id=113
        translate db (Trim m k) = do
          -- Get the key of the first element in the map.
          mh <- withIter db defaultReadOptions { fillCache = False } $ \it ->
            S.head $ S.keySlice it
              (S.KeyRange (encodeMapKey (mapId m) minBound)
                          (flip compare $ encodeMapKey (mapId m) $ pred k)
              )
              S.Asc
          case mh of
            Nothing -> return []
            -- Try to delete all keys between s and k. This is faster than
            -- reading all the existing keys between s and k and removing just
            -- those when most of the range is inhabited.
            Just s -> let sk = decodeMapKey (mapId m) s
                       in return $ Del s : [ Del $ encodeMapKey (mapId m) i
                                           | i <- [ succ sk .. pred k ]
                                           ]

        -- TODO: @encode@ happens to map natural order to lexicographic order on
        -- the encoding. We should probably do the encoding ourselves to fence
        -- from changes to the package 'binary' departing from this behavior.
        --
        -- We are doing some additional work here to encode integers rather than
        -- naturals while preserving the order.
        encodeMapKey :: ByteString -> Int -> SBS.ByteString
        encodeMapKey m k =
          let sign = fromString $ if k >= 0 then "p" else "m"
              encodedNum = encode $ abs $ if k >= 0 then k else minBound - k
           in toStrict $ BS.concat [ m, fromString "/", sign, encodedNum ]

        decodeMapKey :: ByteString -> SBS.ByteString -> Int
        decodeMapKey m bs =
          let bsk = BS.drop (BS.length m + 1) $ fromStrict bs
           in if BS.null bsk then error "C.D.L.P.LevelDB.decodeMapKey: empty key"
              else if BS.head bsk == fromIntegral (fromEnum 'm') then
                     minBound + decode (BS.tail bsk)
                   else
                     decode $ BS.tail bsk
