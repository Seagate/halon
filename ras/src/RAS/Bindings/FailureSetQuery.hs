{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module RAS.Bindings.FailureSetQuery where

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

graph = Data.Map.fromList [(Data.Text.pack "FailureSetQuery",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "message",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ras_message_header",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty),
                                                                                                                                                                                                                                       (Data.Text.pack "failure_set_query",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaId = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#"),
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data FailureSetQueryMessageFailure_set_query = FailureSetQueryMessageFailure_set_query deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)

instance Data.Binary.Binary FailureSetQueryMessageFailure_set_query

instance Data.Hashable.Hashable FailureSetQueryMessageFailure_set_query

instance Data.Aeson.FromJSON FailureSetQueryMessageFailure_set_query
    where parseJSON (Data.Aeson.Types.Object obj) = do GHC.Base.pure FailureSetQueryMessageFailure_set_query
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON FailureSetQueryMessageFailure_set_query
    where toJSON (FailureSetQueryMessageFailure_set_query) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [])

data FailureSetQueryMessage = FailureSetQueryMessage
  { failureSetQueryMessageRas_message_header :: GHC.Base.Maybe Data.Aeson.Types.Value
  , failureSetQueryMessageFailure_set_query :: FailureSetQueryMessageFailure_set_query
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary FailureSetQueryMessage

instance Data.Hashable.Hashable FailureSetQueryMessage

instance Data.Aeson.FromJSON FailureSetQueryMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure FailureSetQueryMessage GHC.Base.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                                      [] -> GHC.Base.return ()
                                                                                                                                                      es -> GHC.Base.fail GHC.Base.$ Prelude.unlines es);
                                                                                                                                                 GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "ras_message_header") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property failure_set_query missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "failure_set_query") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON FailureSetQueryMessage
    where toJSON (FailureSetQueryMessage a1
                                         a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ras_message_header") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                               (,) (Data.Text.pack "failure_set_query") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a2])

data FailureSetQuery = FailureSetQuery
  { failureSetQueryMessage :: FailureSetQueryMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary FailureSetQuery

instance Data.Hashable.Hashable FailureSetQuery

instance Data.Aeson.FromJSON FailureSetQuery
    where parseJSON (Data.Aeson.Types.Object obj) = do GHC.Base.pure FailureSetQuery GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property message missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "message") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON FailureSetQuery
    where toJSON (FailureSetQuery a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a1])