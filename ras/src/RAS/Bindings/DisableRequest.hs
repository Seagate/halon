{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module RAS.Bindings.DisableRequest where

import Control.Monad
import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Aeson.Types
import Data.Binary
import Data.Foldable
import Data.Functor
import Data.HashMap.Lazy
import Data.Hashable
import Data.Map
import Data.Maybe
import Data.Ratio
import Data.Text
import Data.Traversable
import Data.Typeable
import Data.Vector
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

graph = Data.Map.fromList [(Data.Text.pack "DisableRequest",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "message",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ras_message_header",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty),
                                                                                                                                                                                                                                       (Data.Text.pack "failure_set_query_response",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "device",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ArrayType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Device we want to disable")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "disable status",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice2of2 Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaEnum = GHC.Base.Just [Data.Aeson.Types.String (Data.Text.pack "disable"),
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        Data.Aeson.Types.String (Data.Text.pack "enable")]}],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Disabling or enabling")})],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Reply to failure set query")})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaId = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#"),
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data DisableRequestMessageFailure_set_query_response = DisableRequestMessageFailure_set_query_response
  { disableRequestMessageFailure_set_query_responseDevice :: [Data.Aeson.Types.Value] -- ^ Device we want to disable
  , disableRequestMessageFailure_set_query_responseDisablestatus :: Data.Aeson.Types.Value -- ^ Disabling or enabling
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary DisableRequestMessageFailure_set_query_response

instance Data.Hashable.Hashable DisableRequestMessageFailure_set_query_response

instance Data.Aeson.FromJSON DisableRequestMessageFailure_set_query_response
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure DisableRequestMessageFailure_set_query_response GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property device missing") (\val -> case val of
                                                                                                                                                                                                                    Data.Aeson.Types.Array arr -> do Data.Traversable.mapM Data.Aeson.parseJSON (Data.Vector.toList arr)
                                                                                                                                                                                                                    _ -> GHC.Base.fail "not an array") (Data.HashMap.Lazy.lookup (Data.Text.pack "device") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property disable status missing") (\val -> do {Control.Monad.unless (val `Data.Foldable.elem` [Data.Aeson.Types.String (Data.Text.pack "disable"),
                                                                                                                                                                                                                                                                                                                                                                                                                                                                       Data.Aeson.Types.String (Data.Text.pack "enable")]) (GHC.Base.fail "not one of the values in enum");
                                                                                                                                                                                                                                                                                                                                                                                                                       (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaEnum = GHC.Base.Just [Data.Aeson.Types.String (Data.Text.pack "disable"),
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                       Data.Aeson.Types.String (Data.Text.pack "enable")]} val of
                                                                                                                                                                                                                                                                                                                                                                                                                                         [] -> GHC.Base.return ()
                                                                                                                                                                                                                                                                                                                                                                                                                                         es -> GHC.Base.fail GHC.Base.$ Prelude.unlines es);
                                                                                                                                                                                                                                                                                                                                                                                                                                    GHC.Base.return val}) val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "disable status") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON DisableRequestMessageFailure_set_query_response
    where toJSON (DisableRequestMessageFailure_set_query_response a1
                                                                  a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "device") Data.Functor.<$> (GHC.Base.Just GHC.Base.. (Data.Aeson.Types.Array GHC.Base.. (Data.Vector.fromList GHC.Base.. GHC.Base.map Data.Aeson.toJSON))) a1,
                                                                                                                                                                        (,) (Data.Text.pack "disable status") Data.Functor.<$> (GHC.Base.Just GHC.Base.. GHC.Base.id) a2])

data DisableRequestMessage = DisableRequestMessage
  { disableRequestMessageRas_message_header :: GHC.Base.Maybe Data.Aeson.Types.Value
  , disableRequestMessageFailure_set_query_response :: DisableRequestMessageFailure_set_query_response -- ^ Reply to failure set query
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary DisableRequestMessage

instance Data.Hashable.Hashable DisableRequestMessage

instance Data.Aeson.FromJSON DisableRequestMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure DisableRequestMessage GHC.Base.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                                     [] -> GHC.Base.return ()
                                                                                                                                                     es_1 -> GHC.Base.fail GHC.Base.$ Prelude.unlines es_1);
                                                                                                                                                GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "ras_message_header") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property failure_set_query_response missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "failure_set_query_response") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON DisableRequestMessage
    where toJSON (DisableRequestMessage a1
                                        a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ras_message_header") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                              (,) (Data.Text.pack "failure_set_query_response") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a2])

data DisableRequest = DisableRequest
  { disableRequestMessage :: DisableRequestMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary DisableRequest

instance Data.Hashable.Hashable DisableRequest

instance Data.Aeson.FromJSON DisableRequest
    where parseJSON (Data.Aeson.Types.Object obj) = do GHC.Base.pure DisableRequest GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property message missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "message") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON DisableRequest
    where toJSON (DisableRequest a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a1])