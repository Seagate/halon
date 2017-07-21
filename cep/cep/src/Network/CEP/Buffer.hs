{-# LANGUAGE CPP #-} -- XXX DELETEME
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
    , bufferInsertXXX -- XXX DELETEME
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
import Data.Sequence hiding (null)
import qualified Data.Sequence as S -- XXX DELETEME
import Data.UUID (UUID) -- XXX DELETEME
import Debug.Trace (trace) -- XXX DELETEME

-- XXX DELETEME <<<<<<<
showXXX :: String -> Integer -> String -> String
showXXX func line rest = "XXX [" ++ func ++ ":" ++ show line ++ "]" ++ rest'
  where
    rest' = if null rest then "" else ' ':rest
-- XXX DELETEME >>>>>>>

data Input a where
    Insert  :: Typeable e => e -> Input Buffer
    InsertXXX :: Typeable e => (UUID, e) -> Input Buffer
    -- | @Get i@ pops the first (leftmost) element with index > @i@ and matching type signature.
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
  deriving Show

type Index = Int

initIndex :: Index
initIndex = -1

fifoBuffer :: FIFOType -> Buffer
fifoBuffer tpe | trace (showXXX "fifoBuffer" __LINE__ $ show tpe) False = undefined
fifoBuffer tpe = Buffer $ go empty 0
  where
    showBufferXXX :: Seq (Index, Dynamic) -> String
    showBufferXXX xs = "Buffer length=" ++ show (length xs) ++ " range=" ++ showRange (start, end)
      where
        showRange _ | S.null xs   = "[]"
        showRange (x, y) | x == y = "[" ++ show x ++ "]"
        showRange (x, y)          = "[" ++ show x ++ ".." ++ show y ++ "]"
        start = let (i, _) :< _ = viewl xs in i
        end   = let _ :> (i, _) = viewr xs in i
    -- showBufferXXXL :: Seq (Index, Dynamic) -> String
    -- showBufferXXXL xs = "Buffer length=" ++ show (length xs) ++ " " ++ show (toList xs)

    go :: forall a. Seq (Index, Dynamic) -> Index -> Input a -> a
    -- XXX DELETEME <<<<<<<
    go xs idx (InsertXXX (uuid, e)) | trace (showXXX "fifoBuffer.go" __LINE__ $ showBufferXXX xs ++ "; idx=" ++ show idx ++ "; Insert (e :: " ++ show (typeOf e) ++ "); " ++ show uuid) False = undefined
    go xs idx (InsertXXX (_, e)) =
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
    -- XXX DELETEME >>>>>>>
    go xs idx (Insert e) | trace (showXXX "fifoBuffer.go" __LINE__ $ showBufferXXX xs ++ "; idx=" ++ show idx ++ "; Insert (e :: " ++ show (typeOf e) ++ ")") False = undefined
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
    go xs idx (Get i) | trace (showXXX "fifoBuffer.go" __LINE__ $ showBufferXXX xs ++ "; idx=" ++ show idx ++ "; Get " ++ show i) False = undefined
    go xs idx (Get i) =
        let loop acc cur =
              case viewl cur of
                EmptyL -> trace (showXXX "fifoBuffer.go" __LINE__ $ showBufferXXX xs ++ "; idx=" ++ show idx ++ "; Get " ++ show i ++ " ==> Nothing") Nothing
                elm@(ei, e) :< rest
                  | i < ei
                  , Just a <- fromDynamic e ->
                    let nxt_xs = acc >< rest in
                    trace (showXXX "fifoBuffer.go" __LINE__ $ showBufferXXX xs ++ "; idx=" ++ show idx ++ "; Get " ++ show i ++ " ==> Just (" ++ show ei ++ ", a :: " ++ show (typeOf a) ++ ", _)") $ Just (ei, a, Buffer $ go nxt_xs idx)
                  | otherwise -> loop (acc |> elm) rest in
        loop empty xs
    go xs _ Length = length xs
    go xs _ Display = show $ toList xs
    go xs _ Indexes = toList $ fmap fst xs
    go xs idx (Drop i) | trace (showXXX "fifoBuffer.go" __LINE__ $ showBufferXXX xs ++ "; idx=" ++ show idx ++ "; Drop " ++ show i) False = undefined
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

bufferInsertXXX :: Typeable a => (UUID, a) -> Buffer -> Buffer
bufferInsertXXX (uuid, a) (Buffer k) = k $ InsertXXX (uuid, a)

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
