{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module RAS.Bindings.ProcessingError where

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

graph = Data.Map.fromList [(Data.Text.pack "ProcessingError",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "message",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ras_message_header",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty),
                                                                                                                                                                                                                                       (Data.Text.pack "processing_error",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "error",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Error description")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "device",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "UUID of the message causing the error")})],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Processing error")})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaId = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#"),
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data ProcessingErrorMessageProcessing_error = ProcessingErrorMessageProcessing_error
  { processingErrorMessageProcessing_errorError :: Data.Text.Text -- ^ Error description
  , processingErrorMessageProcessing_errorDevice :: Data.Text.Text -- ^ UUID of the message causing the error
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ProcessingErrorMessageProcessing_error

instance Data.Hashable.Hashable ProcessingErrorMessageProcessing_error

instance Data.Aeson.FromJSON ProcessingErrorMessageProcessing_error
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ProcessingErrorMessageProcessing_error GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property error missing") (\val -> case val of
                                                                                                                                                                                                          Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                          _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "error") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property device missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                    Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                    _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "device") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ProcessingErrorMessageProcessing_error
    where toJSON (ProcessingErrorMessageProcessing_error a1
                                                         a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "error") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                               (,) (Data.Text.pack "device") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ProcessingErrorMessage = ProcessingErrorMessage
  { processingErrorMessageRas_message_header :: GHC.Base.Maybe Data.Aeson.Types.Value
  , processingErrorMessageProcessing_error :: ProcessingErrorMessageProcessing_error -- ^ Processing error
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ProcessingErrorMessage

instance Data.Hashable.Hashable ProcessingErrorMessage

instance Data.Aeson.FromJSON ProcessingErrorMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ProcessingErrorMessage GHC.Base.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                                      [] -> GHC.Base.return ()
                                                                                                                                                      es -> GHC.Base.fail GHC.Base.$ Prelude.unlines es);
                                                                                                                                                 GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "ras_message_header") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property processing_error missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "processing_error") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ProcessingErrorMessage
    where toJSON (ProcessingErrorMessage a1
                                         a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ras_message_header") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                               (,) (Data.Text.pack "processing_error") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a2])

data ProcessingError = ProcessingError
  { processingErrorMessage :: ProcessingErrorMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ProcessingError

instance Data.Hashable.Hashable ProcessingError

instance Data.Aeson.FromJSON ProcessingError
    where parseJSON (Data.Aeson.Types.Object obj) = do GHC.Base.pure ProcessingError GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property message missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "message") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ProcessingError
    where toJSON (ProcessingError a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a1])