{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright : (C) 2015 Seagate Technology LLC and/or its Affiliates.
--
-- Buffer data structure used to store CEP engine message
module Network.CEP.Buffer
    ( FIFOType(..)
    , Buffer
    , Index
    , initIndex
    , bufferInsert
    , bufferGetWithIndex
    , bufferGet
    , bufferLength
    , bufferPeek
    , bufferEmpty
    , bufferDrop
    , fifoBuffer
    , emptyFifoBuffer
    , merelyEqual
    ) where

import           Data.Dynamic
import           Data.Typeable (TypeRep, typeOf)
import           Data.Foldable (toList)
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

data Input a where
    Insert  :: Typeable e => e -> Input Buffer
    Get     :: Typeable e => Index -> Input (Maybe (Index, e, Buffer))
    Length  :: Input Int
    Display :: Input String
    Indexes :: Input [Index]
    Drop    :: Index -> Input Buffer

newtype Buffer = Buffer (forall a. Input a -> a)

-- | FIFO insert strategies.
data FIFOType
    = Unbounded
      -- ^ The message list grows endlessly as soon as message are inserted
    | Bounded Int
      -- ^ `Bounded i` when `i` messages are already in the buffer, discards
      --   the older one when a new message is inserted.

type Index = Int

initIndex :: Index
initIndex = (-1)

fifoBuffer :: FIFOType -> Buffer
fifoBuffer tpe = Buffer $ go Map.empty 0
  where
    go :: forall a. Map (TypeRep, Index) Dynamic -> Index -> Input a -> a
    go mm idx (Insert e) =
        let mm'  = Map.insert (typeOf e, idx) (toDyn e) mm
            idx' = succ idx
        in case tpe of
          Bounded limit | Map.size mm >= limit
            -> go mm' idx' $ Drop (idx' - limit)
          _ -> Buffer $ go mm' idx'
    go mm idx (Get i) = do
        let Just (_, x, _) = undefined :: a
        (k@(_, ei), d) <- Map.lookupGT (typeOf x, i) mm
        e <- fromDynamic d
        let mm' = Map.delete k mm
        return (ei, e, Buffer $ go mm' idx)
    go mm _ Length = Map.size mm
    go mm _ Display = show $ toList mm
    go mm _ Indexes = snd <$> Map.keys mm
    go mm idx (Drop i) =
        let mm' = Map.filterWithKey (\(_, ei) _ -> ei >= i) mm
        in Buffer $ go mm' idx

instance Show Buffer where
    show (Buffer k) = k Display

merelyEqual :: Buffer -> Buffer -> Bool
merelyEqual (Buffer ka) (Buffer kb) = ka Indexes == kb Indexes

-- | Inserts a new message.
bufferInsert :: Typeable a => a -> Buffer -> Buffer
bufferInsert a (Buffer k) = k (Insert a)

-- | Gets the first matching type message along with its order of appearance.
--   Returned message is removed from the buffer.
bufferGetWithIndex :: Typeable a
                   => Index
                   -> Buffer
                   -> Maybe (Index, a, Buffer)
bufferGetWithIndex idx (Buffer k) = k (Get idx)

-- | Gets the first matching type message. Returned message is removed from the
--   buffer.
bufferGet :: Typeable a => Buffer -> Maybe (Index, a, Buffer)
bufferGet = bufferGetWithIndex initIndex

bufferPeek :: Typeable a => Index -> Buffer -> Maybe (Index, a)
bufferPeek idx = fmap go . bufferGetWithIndex idx
  where
    go (i, a, _) = (i, a)

-- | Drop all messages with index lower then current.
bufferDrop :: Index -> Buffer -> Buffer
bufferDrop idx (Buffer k) = k (Drop idx)

-- | Gets the buffer's length.
bufferLength :: Buffer -> Int
bufferLength (Buffer k) = k Length

bufferEmpty :: Buffer -> Bool
bufferEmpty b = bufferLength b == 0

emptyFifoBuffer :: Buffer
emptyFifoBuffer = fifoBuffer Unbounded
