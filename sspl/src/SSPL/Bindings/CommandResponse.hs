{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.CommandResponse where

import Control.Monad
import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Helpers
import Data.Aeson.Schema.Types
import Data.Aeson.Types
import Data.Aeson.Types
import Data.Binary
import Data.Either
import Data.Functor
import Data.HashMap.Lazy
import Data.Map
import Data.Maybe
import Data.Ratio
import Data.Scientific
import Data.Text
import Data.Traversable
import Data.Typeable
import Data.Vector
import GHC.Base
import GHC.Classes
import GHC.Generics
import GHC.Num
import GHC.Show
import Prelude
import SSPL.Bindings.Instances ()
import Text.Regex
import Text.Regex.PCRE.String

graph :: Data.Aeson.Schema.Types.Graph Data.Aeson.Schema.Types.Schema
                                       Data.Text.Text

graph = Data.Map.fromList [(Data.Text.pack "CommandResponse",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "signature",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Authentication signature of message")}),
                                                                                                                                 (Data.Text.pack "time",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "The time the signature was generated")}),
                                                                                                                                 (Data.Text.pack "expires",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.IntegerType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "The number of secs the signature remains valid after being generated")}),
                                                                                                                                 (Data.Text.pack "username",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Username who generated message")}),
                                                                                                                                 (Data.Text.pack "message",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "statusResponse",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ArrayType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaItems = GHC.Base.Just (Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                                                                                                                                             Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "status",
                                                                                                                                                                                                                                                                                                                                                                                                                                                                     Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Entity status.")}),
                                                                                                                                                                                                                                                                                                                                                                                                                                                                    (Data.Text.pack "entityId",
                                                                                                                                                                                                                                                                                                                                                                                                                                                                     Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Entity identifier. Depends on entity type.")})]}),
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaUniqueItems = Prelude.True}),
                                                                                                                                                                                                                                       (Data.Text.pack "responseId",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Identity of the message this is sent in response to.")}),
                                                                                                                                                                                                                                       (Data.Text.pack "messageId",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Used to identify a response if a response is required.")})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data CommandResponseMessageStatusResponseItem = CommandResponseMessageStatusResponseItem
  { commandResponseMessageStatusResponseItemStatus :: Data.Text.Text -- ^ Entity status.
  , commandResponseMessageStatusResponseItemEntityId :: Data.Text.Text -- ^ Entity identifier. Depends on entity type.
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary CommandResponseMessageStatusResponseItem

instance Data.Aeson.FromJSON CommandResponseMessageStatusResponseItem
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure CommandResponseMessageStatusResponseItem GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property status missing") (\val -> case val of
                                                                                                                                                                                                             Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                             _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "status") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property entityId missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                          Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                          _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "entityId") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON CommandResponseMessageStatusResponseItem
    where toJSON (CommandResponseMessageStatusResponseItem a1
                                                           a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "status") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                 (,) (Data.Text.pack "entityId") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data CommandResponseMessage = CommandResponseMessage
  { commandResponseMessageStatusResponse :: GHC.Base.Maybe ([CommandResponseMessageStatusResponseItem])
  , commandResponseMessageResponseId :: GHC.Base.Maybe Data.Text.Text -- ^ Identity of the message this is sent in response to.
  , commandResponseMessageMessageId :: GHC.Base.Maybe Data.Text.Text -- ^ Used to identify a response if a response is required.
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary CommandResponseMessage

instance Data.Aeson.FromJSON CommandResponseMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do ((GHC.Base.pure CommandResponseMessage GHC.Base.<*> Data.Traversable.traverse (\val -> case val of
                                                                                                                                                  Data.Aeson.Types.Array arr -> do {Control.Monad.unless (Data.Aeson.Schema.Helpers.vectorUnique arr) (GHC.Base.fail "array items must be unique");
                                                                                                                                                                                    Data.Traversable.mapM Data.Aeson.parseJSON (Data.Vector.toList arr)}
                                                                                                                                                  _ -> GHC.Base.fail "not an array") (Data.HashMap.Lazy.lookup (Data.Text.pack "statusResponse") obj)) GHC.Base.<*> Data.Traversable.traverse (\val -> case val of
                                                                                                                                                                                                                                                                                                           Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                           _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "responseId") obj)) GHC.Base.<*> Data.Traversable.traverse (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                                _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "messageId") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON CommandResponseMessage
    where toJSON (CommandResponseMessage a1
                                         a2
                                         a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "statusResponse") Data.Functor.<$> GHC.Base.fmap (Data.Aeson.Types.Array GHC.Base.. (Data.Vector.fromList GHC.Base.. GHC.Base.map Data.Aeson.toJSON)) a1,
                                                                                                                                               (,) (Data.Text.pack "responseId") Data.Functor.<$> GHC.Base.fmap Data.Aeson.Types.String a2,
                                                                                                                                               (,) (Data.Text.pack "messageId") Data.Functor.<$> GHC.Base.fmap Data.Aeson.Types.String a3])

data CommandResponse = CommandResponse
  { commandResponseSignature :: Data.Text.Text -- ^ Authentication signature of message
  , commandResponseTime :: Data.Text.Text -- ^ The time the signature was generated
  , commandResponseExpires :: GHC.Base.Maybe Prelude.Integer -- ^ The number of secs the signature remains valid after being generated
  , commandResponseUsername :: Data.Text.Text -- ^ Username who generated message
  , commandResponseMessage :: CommandResponseMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary CommandResponse

instance Data.Aeson.FromJSON CommandResponse
    where parseJSON (Data.Aeson.Types.Object obj) = do ((((GHC.Base.pure CommandResponse GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property signature missing") (\val -> case val of
                                                                                                                                                                                          Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                          _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "signature") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property time missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                      Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                      _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "time") obj)) GHC.Base.<*> Data.Traversable.traverse (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     Data.Aeson.Types.Number num -> case Data.Scientific.floatingOrInteger num of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        Data.Either.Right i -> do GHC.Base.return i
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        _ -> GHC.Base.fail "not an integer"
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     _ -> GHC.Base.fail "not an integer") (Data.HashMap.Lazy.lookup (Data.Text.pack "expires") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property username missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "username") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property message missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "message") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON CommandResponse
    where toJSON (CommandResponse a1
                                  a2
                                  a3
                                  a4
                                  a5) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "signature") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                        (,) (Data.Text.pack "time") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2,
                                                                                                                                        (,) (Data.Text.pack "expires") Data.Functor.<$> GHC.Base.fmap (Data.Aeson.Types.Number GHC.Base.. GHC.Num.fromInteger) a3,
                                                                                                                                        (,) (Data.Text.pack "username") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a4,
                                                                                                                                        (,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a5])