{-# LANGUAGE GADTs      #-}
{-# LANGUAGE Rank2Types #-}
-- |
-- Copyright : (C) 2015 Seagate Technology Limited.
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

import Prelude hiding (length)
import Data.Dynamic
import Data.Foldable (toList)

import Data.Sequence

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
fifoBuffer tpe = Buffer $ go empty 0
  where
    go :: forall a. Seq (Index, Dynamic) -> Int -> Input a -> a
    go xs idx (Insert e) =
        case tpe of
          Bounded limit
            | length xs == limit ->
              let _ :< rest = viewl xs
                  nxt_xs    = rest |> (idx, toDyn e)
                  nxt_idx   = succ idx in
              Buffer $ go nxt_xs nxt_idx
            | otherwise ->
              let nxt_xs  = xs |> (idx, toDyn e)
                  nxt_idx = succ idx in
              Buffer $ go nxt_xs nxt_idx
          Unbounded ->
            let nxt_xs  = xs |> (idx, toDyn e)
                nxt_idx = succ idx in
            Buffer $ go nxt_xs nxt_idx
    go xs idx (Get i) =
        let loop acc cur =
              case viewl cur of
                EmptyL -> Nothing
                elm@(ei, e) :< rest
                  | i < ei
                  , Just a <- fromDynamic e ->
                    let nxt_xs =  acc >< rest in
                    Just (ei, a, Buffer $ go nxt_xs idx)
                  | otherwise -> loop (acc |> elm) rest in
        loop empty xs
    go xs _ Length = length xs
    go xs _ Display = show $ toList xs
    go xs _ Indexes = toList $ fmap fst xs
    go xs idx (Drop i) =
        let loop cur =
              case viewl cur of
                EmptyL -> Buffer $ go empty idx
                elm@(ei, _) :< rest
                  | ei < i -> loop rest
                  | otherwise -> Buffer $ go (elm <| rest) idx in
        loop xs

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
