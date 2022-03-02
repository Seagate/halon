{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DeriveFunctor          #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE Rank2Types             #-}
{-# LANGUAGE RecordWildCards        #-}
{-# LANGUAGE TemplateHaskell        #-}
-- |
-- Module    : HA.Service.Interface
-- Copyright : (C) 2017 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Interface serving as a communication shim between services and RC.
--
-- The idea is to unify the set of possible messages into a union and
-- have a single place where the communication implementation lives
-- for a service. This allows for further hiding of any extra details
-- such as version exchanges and updates from the rest of the service
-- code.
module HA.Service.Interface
  ( ServiceName
  , WireFormat(..)
  , Version(..)
  , DecodeResult(..)
  , Interface(..)
  , sendSvc
  , returnSvcMsg
  , sendRC
  , receiveSvcIf
  , receiveSvc
  , reencodeWireFormat
  , returnedFromSvc
  , returnToSvc
  , receiveSvcFailure
  , unsafeResendUnwrapped
  -- * Helpers
  , mkWf
  , safeDecode
  , safeEncode
  )
  where

import           Control.Distributed.Process
import           Control.Distributed.Process.Internal.Types (Message(..))
import qualified Control.Distributed.Process.Serializable as FP
import qualified Data.Binary as B
import qualified Data.ByteString as BS
import           Data.Functor
import           Data.Maybe (isJust, isNothing)
import qualified Data.Serialize.Get as S
import qualified Data.Serialize.Put as S
import           Data.Typeable
import           GHC.Generics (Generic)
import           GHC.Word (Word8)
import           HA.EventQueue.Producer (promulgateWait)
import           HA.SafeCopy hiding (Version)
import           Network.CEP (liftProcess, MonadProcess)
import           Text.Printf (printf)
import           Unsafe.Coerce (unsafeCoerce)

-- | Alias for service names.
type ServiceName = String

-- | An on-wire format containing encoded data.
data WireFormat i = WireFormat
  { wfServiceName :: !ServiceName
  -- ^ Name of the service this message is for/from. Used for looking
  -- up according interface.
  , wfServiceNode :: !(Maybe NodeId)
  -- ^ Node on which the service is on. If a message from service
  -- fails to decode, the RC has to know where to send a request for
  -- re-encode. This is only needed one way: service always knows how
  -- to send to RC through EQ.
  , wfSenderVersion :: !Version
  -- ^ Version of the sender of the message.
  , wfReceiverVersion :: !(Maybe Version)
  -- ^ When a message is received and can not be decoded because we
  -- don't know how to do so on the receiving side, the receiver
  -- should fill this field with its own version and send it back to
  -- the sender. The sender can then examine if it's filled and try to
  -- re-encode the message to match the receiver's version.
  , wfPayload :: !BS.ByteString
  } deriving (Show, Generic, Typeable, Functor)

-- | Version wrapper.
newtype Version = Version Word8
  deriving (Show, Eq, Ord, Num, Enum)

-- | Result of decoding a 'WireFormat' message.
data DecodeResult a = DecodeOk !a
                    -- ^ We have managed to decode the message,
                    -- provides content.
                    | DecodeFailed !String
                    -- ^ The decode failed with the given reason.
                    | DecodeVersionMismatch
                    -- ^ Decoding failed because this decoder doesn't
                    -- know how to deal with the message.
                    deriving (Show, Eq, Ord, Generic, Typeable, Functor)

-- | Interface type that services should define.
--
-- TODO: Consider smart constructor instead such that we can enforce
-- version checks in front of ifDecodeFromSvc rather than making RC do
-- it.
data Interface toSvc fromSvc = Interface
  { ifVersion :: !Version
    -- ^ Version of the interface. This is used for checking if we're
    -- talking to a different version on the other side: it is up to
    -- the programmer to increment this in the interface
    -- implementation when making incompatible changes.
  , ifServiceName :: !ServiceName
  , ifEncodeToSvc :: Version -> toSvc -> Maybe (WireFormat toSvc)
    -- ^ Encode a message being sent to the service into a
    -- 'WireFormat'. Used when sending a message from RC to a service.
  , ifDecodeToSvc :: WireFormat toSvc -> DecodeResult toSvc
    -- ^ Decode a service message from 'WireFormat'. Used by a service
    -- when receiving a message from RC.
  , ifEncodeFromSvc :: Version -> fromSvc -> Maybe (WireFormat fromSvc)
    -- ^ Encode a message being sent from the service to RC. Used by a
    -- service when sending.
  , ifDecodeFromSvc :: WireFormat fromSvc -> DecodeResult fromSvc
    -- ^ Decode a message sent from the service to RC. Used by RC when
    -- receiving a message from a service.
  }

instance Show (Interface a b) where
  show i = printf "Interface { ifVersion = %s, ifServiceName = %s }"
                  (show $ ifVersion i) (ifServiceName i)

-- | Send the given message to the service registered on the given
-- node.
sendSvc :: (Typeable toSvc, MonadProcess m, Show toSvc)
        => Interface toSvc a -> NodeId -> toSvc -> m ()
sendSvc Interface{..} nid toSvc = liftProcess $! case ifEncodeToSvc ifVersion toSvc of
  Nothing -> say $ printf "Unable to send %s to %s" (show toSvc) ifServiceName
  Just !wf -> nsendRemote nid (printf "service.%s" ifServiceName) wf

-- | Return a message from a service back to it, asking it to
-- re-encode the message to the given version.
--
-- [Cycle]: Maybe we want to check 'wfReceiverVersion' here and do not
-- return the message if it has been set: with bad code, we could
-- potentially run ourselves into bouncing a message neither side can
-- decode. It's a pathological scenario however.
returnSvcMsg :: (MonadProcess m, Typeable fromSvc, Show fromSvc)
             => Interface a fromSvc -> WireFormat fromSvc -> m ()
returnSvcMsg Interface{..} wf = liftProcess $! case wfServiceNode wf of
  Nothing -> say $ printf "Unable to send message back to %s, no node set: %s"
                          ifServiceName (show wf)
  Just nid -> nsendRemote nid (printf "service.%s" ifServiceName) $
    wf { wfReceiverVersion = Just ifVersion, wfServiceNode = Nothing }
    `asTypeOf` wf

-- | Send a message from the service to the RC over the service interface.
--   This should handle differing versions between the RC and the service.
sendRC :: (Typeable fromSvc, Show fromSvc)
       => Interface a fromSvc -> fromSvc -> Process ()
sendRC Interface{..} fromSvc = case ifEncodeFromSvc ifVersion fromSvc of
  Nothing -> say $ printf "Unable to send %s to RC from %s with version %s."
                          (show fromSvc) ifServiceName (show ifVersion)
  Just !wf -> do
    nid <- getSelfNode
    promulgateWait . void $ wf { wfServiceNode = Just nid }

receiveSvcIf :: (Typeable toSvc, Show toSvc)
             => Interface toSvc a -> (toSvc -> Bool) -> (toSvc -> Process b) -> Match b
receiveSvcIf Interface{..} p act = matchIf predicates $ \wf -> do
  case ifDecodeToSvc wf of
    DecodeOk toSvc -> act toSvc
    -- ‘impossible’ cases follow because matchIf sucks
    DecodeVersionMismatch -> do
      let msg = printf "%s unable to decode %s due to version" ifServiceName (show wf)
      say msg
      return $ error msg
    DecodeFailed err -> do
      let msg = printf "%s unable to decode %s: %s" ifServiceName (show wf) err
      say msg
      return $ error msg
  where
    -- Check that interface is higher or equal version than the
    -- message, the decode goes fine and that user predicate passes on
    -- decode result.
    predicates wf = ifVersion >= wfSenderVersion wf
                    && isNothing (wfReceiverVersion wf)
                    && decodeOk (ifDecodeToSvc wf)

    decodeOk (DecodeOk a) = p a
    decodeOk _ = False

-- | 'Match' any message to the service that the interface can decode.
--
-- Messages that can not be decoded due to any reason including
-- version mismatch are not processed.
receiveSvc :: (Typeable toSvc, Show toSvc)
           => Interface toSvc a -> (toSvc -> Process b) -> Match b
receiveSvc iface act = receiveSvcIf iface (const True) act

-- | Re-encode a returned 'WireFormat' message to the version
-- specified by 'wfReceiverVersion'.
reencodeWireFormat :: MonadProcess m
                   => WireFormat t
                   -- ^ Messsage itself
                   -> (WireFormat t -> DecodeResult t)
                   -- ^ Decoder
                   -> (Version -> t -> Maybe (WireFormat t'))
                   -- ^ Encoder
                   -> m (Maybe (WireFormat t'))
reencodeWireFormat wf decoder encoder = case wfReceiverVersion wf of
  Just lowVersion -> case decoder wf of
    DecodeOk t -> case encoder lowVersion t of
      Just !wf' -> do
        nid <- liftProcess getSelfNode
        -- Lower the version in re-encoded version
        return . Just $! wf' { wfSenderVersion = lowVersion
                             , wfReceiverVersion = Nothing
                             , wfServiceNode = Just nid }
      Nothing -> return Nothing
    -- service couldn't decode its own message…
    _ -> return Nothing
  Nothing -> return Nothing

-- | The service received a message that was initially sent by it with
-- 'wfReceiverVersion' filled. This means RC couldn't process the
-- message and is asking us to re-encode it then send it back.
returnedFromSvc :: (Typeable fromSvc, Show fromSvc)
                => Interface a fromSvc -> Process b -> Match b
returnedFromSvc Interface{..} act = matchIf reencodeRequest $ \wf -> do
  reencodeWireFormat wf ifDecodeFromSvc ifEncodeFromSvc >>= \case
    Just !wf' -> do
      nid <- getSelfNode
      promulgateWait . void $ wf' { wfServiceNode = Just nid }
    -- We can't re-encode, just give up.
    Nothing -> say $ printf "%s.returnedFromSvc couldn't re-encode %s"
                            ifServiceName (show wf)
  act
  where
    reencodeRequest = isJust . wfReceiverVersion

-- | RC sent a message to service but it the service was unable to
-- process it and asked for RC to re-send it re-encoded.
returnToSvc :: (MonadProcess m, Typeable toSvc, Show toSvc)
              => Interface toSvc a -> WireFormat toSvc -> m ()
returnToSvc Interface{..} wf = liftProcess $! case wfReceiverVersion wf of
  Just{} -> case wfServiceNode wf of
    Just nid -> reencodeWireFormat wf ifDecodeToSvc ifEncodeToSvc >>= \case
      Just !wf' -> nsendRemote nid (printf "service.%s" ifServiceName) $
        wf' { wfServiceNode = Nothing } `asTypeOf` wf'
      Nothing -> say $ printf "%s.returnToSvc couldn't re-encode %s"
                              ifServiceName (show wf)
    Nothing -> say $ printf "%s.returnToSvc no node set for %s"
                            ifServiceName (show wf)
  Nothing -> say $ printf "%s.returnToSvc no version set for %s"
                           ifServiceName (show wf)

-- | Process a decode failure. If it's a version mismatch, send the
-- message back to RC asking it to re-encode to the version we need.
--
-- Note that messages which aren't the right version but could still
-- decode are explicitly rejected: we can not do sane things if old
-- service happens to accept new messages because they look similar.
-- If we bumped an interface version, we probably meant it.
receiveSvcFailure :: (Typeable toSvc, Show toSvc)
                  => Interface toSvc a -> Process b -> Match b
receiveSvcFailure Interface{..} act = matchIf predicates $ \wf -> do
  -- Send the message back to RC while filling necessary information
  -- for it to get back to us.
  let requestReencode = do
        nid <- getSelfNode
        promulgateWait . void
          $ wf { wfReceiverVersion = Just ifVersion
               , wfServiceNode = Just nid }
  if ifVersion < wfSenderVersion wf
  -- Don't even waste time trying to decode
  then requestReencode
  else case ifDecodeToSvc wf of
    -- We are within version bounds but the service decoder raised
    -- version mismatch. Shouldn't really happen but just handle
    -- normally.
    DecodeVersionMismatch -> requestReencode
    -- We can't do anything, print message and do nothing more.
    DecodeFailed err -> do
      say $ printf "%s failed to decode %s: %s" ifServiceName (show wf) err
    -- ‘impossible’ due to decodeFail
    DecodeOk s -> do
      let msg = printf "%s managed to decode %s to %s" ifServiceName (show wf) (show s)
      say msg
      return $ error msg
  act
  where
    predicates wf = ifVersion < wfSenderVersion wf
                    || decodeFail (ifDecodeToSvc wf)

    decodeFail DecodeVersionMismatch = True
    decodeFail DecodeFailed{} = True
    decodeFail _ = False

-- | Helper used throughout interface implementations, packing payload
-- into 'WireFormat'.
mkWf :: Interface a b -> BS.ByteString -> WireFormat c
mkWf interface payload = WireFormat
  { wfServiceName = ifServiceName interface
  , wfServiceNode = Nothing
  , wfSenderVersion = ifVersion interface
  , wfReceiverVersion = Nothing
  , wfPayload = payload
  }

-- | Decode 'WireFormat' payload with using its SafeCopy instance.
safeDecode :: SafeCopy a => WireFormat a -> DecodeResult a
safeDecode wf = case S.runGet safeGet $! wfPayload wf of
  Left err -> DecodeFailed err
  Right v -> DecodeOk v

-- | Encode a message into 'WireFormat' using the given interface.
safeEncode :: SafeCopy c => Interface a b -> c -> WireFormat c
safeEncode interface = mkWf interface . S.runPut . safePut

-- | Receive raw 'Message's, decode it and let rest of the service
-- handle the content. You very likely do not want to use this
-- function yourself.
--
-- [localSend]: This function is pretty scary for multiple reasons but
-- the main one is that it is a catch-all function that will send to
-- local process. We're okay for two reasons:
--
-- * We rely on receiving 'EncodedMessage's from the outside which we
--   decode here and we send the content to local node:
--   @distributed-process@ does not encode local messages so the
--   guards here should fail and the message should fall-through.
--
-- * The use of this function is *after* 'WireFormat' handlers (at
--   least it should be!). That gives other handlers a chance to
--   remove the message from mailbox before this function runs again.
unsafeResendUnwrapped :: forall toSvc fromSvc t.
                         (Typeable toSvc, Typeable fromSvc)
                      => Interface toSvc fromSvc
                      -> (Either (WireFormat toSvc) (WireFormat fromSvc) -> t)
                      -- ^ Any handler. Note that this runs after the
                      -- 'matchMessageIf' handler so it sadly has to
                      -- be pure. For our use-case that's OK.
                      -> Match t
unsafeResendUnwrapped Interface{..} act =
  unsafeUnwrapMatch . matchMessageIf (isJust . decodeToWf) $ \m -> do
    -- See [localSend] resendUnwrapped
    let localSend msg = do
          self <- getSelfPid
          usend self msg
          return $! UnencodedMessage (FP.fingerprint msg) msg

    case decodeToWf m of
      Nothing -> do
        let msg = printf "%s.matchIfaceIf decode failed past guard: %s"
                         ifServiceName (show m)
        return $ error msg
      Just (Left !wf) -> localSend wf
      Just (Right !wf) -> localSend wf
  where
    -- We could do incremental decode of WireFormat here and check
    -- wfReceiverVersion to figure out what type is sitting here.
    decodeToWf :: Message -> Maybe (Either (WireFormat toSvc) (WireFormat fromSvc))
    decodeToWf (EncodedMessage _ payload) = case B.decodeOrFail payload of
      Left{} -> case B.decodeOrFail payload of
        -- Don't accept fromSvc if wfReceiverVersion isn't set.
        Right (_, _, !wf) | isJust (wfReceiverVersion wf) -> Just $! Right wf
        _ -> Nothing
      Right (_, _, !wf) -> Just $! Left wf
    decodeToWf _ = Nothing

    -- Use Functor instance for Match to extract and use the content
    -- of the Message.
    unsafeUnwrapMatch :: Match Message -> Match t
    unsafeUnwrapMatch = fmap (act . unsafeUnwrapMessage)

    -- decodeToWf suceeded and left us an Unencoded message.
    unsafeUnwrapMessage :: Message -> Either (WireFormat toSvc) (WireFormat fromSvc)
    unsafeUnwrapMessage (UnencodedMessage fp wf)
      | fp == FP.fingerprint (undefined :: WireFormat toSvc) = Left $! unsafeCoerce wf
      | fp == FP.fingerprint (undefined :: WireFormat fromSvc) = Right $! unsafeCoerce wf
    unsafeUnwrapMessage _ = error "matchIfaceIf.unsafeUnwrapMessage"

-- Necessary for replication
deriveSafeCopy 0 'base ''Version

-- Manual SafeCopy and Binary instance for WireFormat because phantom
-- type introduces constraints we don't need.
instance SafeCopy (WireFormat a) where
  putCopy (WireFormat sname snode sver rver pload) = contain $ do
    safePut sname
    safePut snode
    safePut sver
    safePut rver
    safePut pload
  getCopy = contain $ do
    sname <- safeGet
    snode <- safeGet
    sver <- safeGet
    rver <- safeGet
    pload <- safeGet
    return $ WireFormat sname snode sver rver pload

instance B.Binary (WireFormat a) where
  put = B.put . S.runPutLazy . safePut
  get = B.get >>= either fail return . S.runGetLazy safeGet
