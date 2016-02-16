{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module RAS.Bindings.FailureSetQueryResponse where

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

graph = Data.Map.fromList [(Data.Text.pack "FailureSetQueryResponse",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "message",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ras_message_header",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty),
                                                                                                                                                                                                                                       (Data.Text.pack "failure_set_query_response",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "query_uuid",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "UUID of the request we're replying to")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "failure_set",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ArrayType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "UUID of the request we're replying to")})],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Reply to failure set query")})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaId = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#"),
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data FailureSetQueryResponseMessageFailure_set_query_response = FailureSetQueryResponseMessageFailure_set_query_response
  { failureSetQueryResponseMessageFailure_set_query_responseQuery_uuid :: Data.Text.Text -- ^ UUID of the request we're replying to
  , failureSetQueryResponseMessageFailure_set_query_responseFailure_set :: [Data.Aeson.Types.Value] -- ^ UUID of the request we're replying to
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary FailureSetQueryResponseMessageFailure_set_query_response

instance Data.Hashable.Hashable FailureSetQueryResponseMessageFailure_set_query_response

instance Data.Aeson.FromJSON FailureSetQueryResponseMessageFailure_set_query_response
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure FailureSetQueryResponseMessageFailure_set_query_response GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property query_uuid missing") (\val -> case val of
                                                                                                                                                                                                                                 Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                 _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "query_uuid") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property failure_set missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                     Data.Aeson.Types.Array arr -> do Data.Traversable.mapM Data.Aeson.parseJSON (Data.Vector.toList arr)
                                                                                                                                                                                                                                                                                                                                                                                                                                     _ -> GHC.Base.fail "not an array") (Data.HashMap.Lazy.lookup (Data.Text.pack "failure_set") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON FailureSetQueryResponseMessageFailure_set_query_response
    where toJSON (FailureSetQueryResponseMessageFailure_set_query_response a1
                                                                           a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "query_uuid") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                                 (,) (Data.Text.pack "failure_set") Data.Functor.<$> (GHC.Base.Just GHC.Base.. (Data.Aeson.Types.Array GHC.Base.. (Data.Vector.fromList GHC.Base.. GHC.Base.map Data.Aeson.toJSON))) a2])

data FailureSetQueryResponseMessage = FailureSetQueryResponseMessage
  { failureSetQueryResponseMessageRas_message_header :: GHC.Base.Maybe Data.Aeson.Types.Value
  , failureSetQueryResponseMessageFailure_set_query_response :: FailureSetQueryResponseMessageFailure_set_query_response -- ^ Reply to failure set query
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary FailureSetQueryResponseMessage

instance Data.Hashable.Hashable FailureSetQueryResponseMessage

instance Data.Aeson.FromJSON FailureSetQueryResponseMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure FailureSetQueryResponseMessage GHC.Base.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                                              [] -> GHC.Base.return ()
                                                                                                                                                              es -> GHC.Base.fail GHC.Base.$ Prelude.unlines es);
                                                                                                                                                         GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "ras_message_header") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property failure_set_query_response missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "failure_set_query_response") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON FailureSetQueryResponseMessage
    where toJSON (FailureSetQueryResponseMessage a1
                                                 a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ras_message_header") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                                       (,) (Data.Text.pack "failure_set_query_response") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a2])

data FailureSetQueryResponse = FailureSetQueryResponse
  { failureSetQueryResponseMessage :: FailureSetQueryResponseMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary FailureSetQueryResponse

instance Data.Hashable.Hashable FailureSetQueryResponse

instance Data.Aeson.FromJSON FailureSetQueryResponse
    where parseJSON (Data.Aeson.Types.Object obj) = do GHC.Base.pure FailureSetQueryResponse GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property message missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "message") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON FailureSetQueryResponse
    where toJSON (FailureSetQueryResponse a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a1])