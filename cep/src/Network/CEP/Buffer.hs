{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE Rank2Types                #-}
{-# LANGUAGE RecordWildCards           #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
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
    , bufferDump
    , fifoBuffer
    ) where

import Data.Dynamic
import Data.Foldable (traverse_)

import Control.Monad.Trans

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

data FIFO =
    FIFO
    { _fifoFixed :: !(Maybe Int)
    , _fifoSize  :: !Int
    , _fifoStep  :: !Int
    , _fifoElems :: ![(Int, Dynamic)]
    }

_fifoNew :: FIFOType -> FIFO
_fifoNew typ =
    FIFO
    { _fifoFixed = case typ of
                     Unbounded -> Nothing
                     Bounded i -> Just i
    , _fifoSize  = 0
    , _fifoStep  = 0
    , _fifoElems = []
    }

_append :: [a] -> a -> [a]
_append xs x = xs ++ [x]

_get :: Typeable a
     => Index
     -> [(Index, Dynamic)]
     -> (Maybe (Index, a), [(Index, Dynamic)])
_get idx = go []
  where
    go acc []     = (Nothing, reverse acc)
    go acc (r@(i,x):xs) =
        case fromDynamic x of
          Just a | idx < i -> (Just (i, a), reverse acc ++ xs)
          _                -> go (r:acc) xs

-- | Buffer storage.
data Buffer =
    forall s.
    Buffer
    { _bufferInsert :: forall a. Typeable a => a -> s -> s
    , _bufferGet    :: forall a. Typeable a => Index -> s -> (Maybe (Index, a), s)
    , _bufferLength :: s -> Int
    , _bufferDump   :: forall m. MonadIO m => s -> m ()
    , _bufferState  :: !s
    }

-- | Inserts a new message.
bufferInsert :: Typeable a => a -> Buffer -> Buffer
bufferInsert a (Buffer bi bg bl dm s) =
    Buffer
    { _bufferInsert = bi
    , _bufferGet    = bg
    , _bufferLength = bl
    , _bufferDump   = dm
    , _bufferState  = bi a s
    }

-- | Gets the first matching type message along with its order of appearance.
--   Returned message is removed from the buffer.
bufferGetWithIndex :: Typeable a
                   => Index
                   -> Buffer
                   -> (Maybe (Index, a), Buffer)
bufferGetWithIndex idx (Buffer bi bg bl dm s) =
    case bg idx s of
      (res, s') ->
        let buf' = Buffer
                   { _bufferInsert = bi
                   , _bufferGet    = bg
                   , _bufferLength = bl
                   , _bufferDump   = dm
                   , _bufferState  = s'
                   } in
        (res, buf')

-- | Gets the first matching type message. Returned message is removed from the
--   buffer.
bufferGet :: Typeable a => Buffer -> (Maybe a, Buffer)
bufferGet buf =
    let (res, buf') = bufferGetWithIndex (-1) buf in (fmap snd res, buf')

bufferPeek :: Typeable a => Index -> Buffer -> Maybe (Index, a)
bufferPeek idx = fst . bufferGetWithIndex idx

-- | Gets the buffer's length.
bufferLength :: Buffer -> Int
bufferLength (Buffer _ _ bl _ s) = bl s

-- | Prints the content of the buffer.
bufferDump :: MonadIO m => Buffer -> m ()
bufferDump (Buffer _ _ _ dm s) = dm s

_bufFifoInsert :: Typeable a => a -> FIFO -> FIFO
_bufFifoInsert a fifo@(FIFO (Just limit) i size xs)
    | size == limit = fifo { _fifoElems = _append (drop 1 xs) (i, toDyn a)
                           , _fifoStep  = i + 1
                           }
    | otherwise     = fifo { _fifoElems = _append xs (i, toDyn a)
                           , _fifoSize  = size + 1
                           , _fifoStep  = i + 1
                           }
_bufFifoInsert a fifo@(FIFO _ size i xs) =
    fifo { _fifoElems = _append xs (i, toDyn a)
         , _fifoSize  = size + 1
         , _fifoStep  = i + 1
         }

_bufFifoGet :: Typeable a => Index -> FIFO -> (Maybe (Index, a), FIFO)
_bufFifoGet idx fifo@(FIFO _ size _ xs) =
    case _get idx xs of
      (Just x, xs') ->
          let fifo' = fifo { _fifoElems = xs'
                           , _fifoSize  = size - 1
                           } in
           (Just x, fifo')
      _             -> (Nothing, fifo)

_bufFifoDump :: MonadIO m => FIFO -> m ()
_bufFifoDump (FIFO _ _ _ xs) = liftIO $ do
    traverse_ print xs
    putStrLn "~~~~~~~~~~~~~~~~~"

-- | FIFO type buffer.
fifoBuffer :: FIFOType -> Buffer
fifoBuffer typ =
    Buffer
    { _bufferInsert = _bufFifoInsert
    , _bufferGet    = _bufFifoGet
    , _bufferLength = _fifoSize
    , _bufferState  = _fifoNew typ
    , _bufferDump   = _bufFifoDump
    }
