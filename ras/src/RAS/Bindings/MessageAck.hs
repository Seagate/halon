{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module RAS.Bindings.MessageAck where

import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Aeson.Types
import Data.Binary
import Data.Functor
import Data.HashMap.Lazy
import Data.Hashable
import Data.Map
import Data.Maybe
import Data.Ratio
import Data.Text
import Data.Traversable
import Data.Typeable
import GHC.Base
import GHC.Classes
import GHC.Generics
import GHC.Show
import Prelude
import RAS.Bindings.Instances ()
import Text.Regex
import Text.Regex.PCRE.String

graph :: Data.Aeson.Schema.Types.Graph Data.Aeson.Schema.Types.Schema
                                       Data.Text.Text

graph = Data.Map.fromList [(Data.Text.pack "MessageAck",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "message",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ras_message_header",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty),
                                                                                                                                                                                                                                       (Data.Text.pack "ack_uuid",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "The UUID of the message we're replying to")})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaId = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#"),
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data MessageAckMessage = MessageAckMessage
  { messageAckMessageRas_message_header :: GHC.Base.Maybe Data.Aeson.Types.Value
  , messageAckMessageAck_uuid :: Data.Text.Text -- ^ The UUID of the message we're replying to
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary MessageAckMessage

instance Data.Hashable.Hashable MessageAckMessage

instance Data.Aeson.FromJSON MessageAckMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure MessageAckMessage GHC.Base.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                                 [] -> GHC.Base.return ()
                                                                                                                                                 es -> GHC.Base.fail GHC.Base.$ Prelude.unlines es);
                                                                                                                                            GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "ras_message_header") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property ack_uuid missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                        Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                        _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "ack_uuid") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON MessageAckMessage
    where toJSON (MessageAckMessage a1
                                    a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ras_message_header") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                          (,) (Data.Text.pack "ack_uuid") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data MessageAck = MessageAck
  { messageAckMessage :: MessageAckMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary MessageAck

instance Data.Hashable.Hashable MessageAck

instance Data.Aeson.FromJSON MessageAck
    where parseJSON (Data.Aeson.Types.Object obj) = do GHC.Base.pure MessageAck GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property message missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "message") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON MessageAck
    where toJSON (MessageAck a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a1])