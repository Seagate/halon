{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.SensorRequest where

import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Aeson.Types
import Data.Binary
import Data.Either
import Data.Foldable
import Data.Functor
import Data.HashMap.Lazy
import Data.Map
import Data.Maybe
import Data.Ratio
import Data.Scientific
import Data.Text
import Data.Traversable
import Data.Tuple
import Data.Typeable
import GHC.Base
import GHC.Classes
import GHC.Generics
import GHC.List
import GHC.Num
import GHC.Show
import Prelude
import SSPL.Bindings.Instances ()
import Text.Regex
import Text.Regex.Base.RegexLike
import Text.Regex.PCRE.String

graph :: Data.Aeson.Schema.Types.Graph Data.Aeson.Schema.Types.Schema
                                       Data.Text.Text

graph = Data.Map.fromList [(Data.Text.pack "SensorRequest",
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
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "sspl_ll_debug",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty),
                                                                                                                                                                                                                                       (Data.Text.pack "sensor_request_type",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "node_data",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "sensor_type",
                                                                                                                                                                                                                                                                                                                                                                                                                                                    Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                  Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Request sensor data; cpu_data, etc.")})],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaAdditionalProperties = Data.Aeson.Schema.Choice.Choice1of2 Prelude.False})],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaAdditionalProperties = Data.Aeson.Schema.Choice.Choice1of2 Prelude.False,
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaRequired = Prelude.True}),
                                                                                                                                                                                                                                       (Data.Text.pack "sspl_ll_msg_header",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaId = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#"),
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data SensorRequestMessageSensor_request_typeNode_data = SensorRequestMessageSensor_request_typeNode_data
  { sensorRequestMessageSensor_request_typeNode_dataSensor_type :: Data.Text.Text -- ^ Request sensor data; cpu_data, etc.
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary SensorRequestMessageSensor_request_typeNode_data

instance Data.Aeson.FromJSON SensorRequestMessageSensor_request_typeNode_data
    where parseJSON (Data.Aeson.Types.Object obj) = do {let items = Data.HashMap.Lazy.toList obj
                                                         in Data.Foldable.forM_ items GHC.Base.$ (\(pname,
                                                                                                    value) -> do {matchingPatterns <- GHC.Base.return (GHC.List.filter (GHC.Base.flip Text.Regex.Base.RegexLike.match (Data.Text.unpack pname) GHC.Base.. (Data.Aeson.Schema.Types.patternCompiled GHC.Base.. Data.Tuple.fst)) []);
                                                                                                                  Data.Foldable.forM_ matchingPatterns GHC.Base.$ (\(_,
                                                                                                                                                                     sch) -> do (case Data.Aeson.Schema.Validator.validate graph sch value of
                                                                                                                                                                                     [] -> GHC.Base.return ()
                                                                                                                                                                                     es -> GHC.Base.fail GHC.Base.$ Prelude.unlines es));
                                                                                                                  isAdditionalProperty <- GHC.Base.return (Data.Foldable.null matchingPatterns GHC.Classes.&& (pname `Data.Foldable.notElem` [Data.Text.pack "sensor_type"]));
                                                                                                                  GHC.Base.when isAdditionalProperty (GHC.Base.fail "additional properties are not allowed")});
                                                        GHC.Base.pure SensorRequestMessageSensor_request_typeNode_data GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property sensor_type missing") (\val -> case val of
                                                                                                                                                                                                                          Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                          _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "sensor_type") obj)}
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON SensorRequestMessageSensor_request_typeNode_data
    where toJSON (SensorRequestMessageSensor_request_typeNode_data a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "sensor_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1])

data SensorRequestMessageSensor_request_type = SensorRequestMessageSensor_request_type
  { sensorRequestMessageSensor_request_typeNode_data :: GHC.Base.Maybe SensorRequestMessageSensor_request_typeNode_data
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary SensorRequestMessageSensor_request_type

instance Data.Aeson.FromJSON SensorRequestMessageSensor_request_type
    where parseJSON (Data.Aeson.Types.Object obj) = do {let items_1 = Data.HashMap.Lazy.toList obj
                                                         in Data.Foldable.forM_ items_1 GHC.Base.$ (\(pname_1,
                                                                                                      value_1) -> do {matchingPatterns_1 <- GHC.Base.return (GHC.List.filter (GHC.Base.flip Text.Regex.Base.RegexLike.match (Data.Text.unpack pname_1) GHC.Base.. (Data.Aeson.Schema.Types.patternCompiled GHC.Base.. Data.Tuple.fst)) []);
                                                                                                                      Data.Foldable.forM_ matchingPatterns_1 GHC.Base.$ (\(_,
                                                                                                                                                                           sch_1) -> do (case Data.Aeson.Schema.Validator.validate graph sch_1 value_1 of
                                                                                                                                                                                             [] -> GHC.Base.return ()
                                                                                                                                                                                             es_1 -> GHC.Base.fail GHC.Base.$ Prelude.unlines es_1));
                                                                                                                      isAdditionalProperty_1 <- GHC.Base.return (Data.Foldable.null matchingPatterns_1 GHC.Classes.&& (pname_1 `Data.Foldable.notElem` [Data.Text.pack "node_data"]));
                                                                                                                      GHC.Base.when isAdditionalProperty_1 (GHC.Base.fail "additional properties are not allowed")});
                                                        GHC.Base.pure SensorRequestMessageSensor_request_type GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "node_data") obj)}
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON SensorRequestMessageSensor_request_type
    where toJSON (SensorRequestMessageSensor_request_type a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "node_data") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a1])

data SensorRequestMessage = SensorRequestMessage
  { sensorRequestMessageSspl_ll_debug :: GHC.Base.Maybe Data.Aeson.Types.Value
  , sensorRequestMessageSensor_request_type :: SensorRequestMessageSensor_request_type
  , sensorRequestMessageSspl_ll_msg_header :: Data.Aeson.Types.Value
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary SensorRequestMessage

instance Data.Aeson.FromJSON SensorRequestMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do ((GHC.Base.pure SensorRequestMessage GHC.Base.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                                     [] -> GHC.Base.return ()
                                                                                                                                                     es_2 -> GHC.Base.fail GHC.Base.$ Prelude.unlines es_2);
                                                                                                                                                GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_debug") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property sensor_request_type missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "sensor_request_type") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property sspl_ll_msg_header missing") (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True} val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                [] -> GHC.Base.return ()
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                es_3 -> GHC.Base.fail GHC.Base.$ Prelude.unlines es_3);
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_msg_header") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON SensorRequestMessage
    where toJSON (SensorRequestMessage a1
                                       a2
                                       a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "sspl_ll_debug") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                             (,) (Data.Text.pack "sensor_request_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a2,
                                                                                                                                             (,) (Data.Text.pack "sspl_ll_msg_header") Data.Functor.<$> (GHC.Base.Just GHC.Base.. GHC.Base.id) a3])

data SensorRequest = SensorRequest
  { sensorRequestSignature :: Data.Text.Text -- ^ Authentication signature of message
  , sensorRequestTime :: Data.Text.Text -- ^ The time the signature was generated
  , sensorRequestExpires :: GHC.Base.Maybe Prelude.Integer -- ^ The number of secs the signature remains valid after being generated
  , sensorRequestUsername :: Data.Text.Text -- ^ Username who generated message
  , sensorRequestMessage :: SensorRequestMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary SensorRequest

instance Data.Aeson.FromJSON SensorRequest
    where parseJSON (Data.Aeson.Types.Object obj) = do ((((GHC.Base.pure SensorRequest GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property signature missing") (\val -> case val of
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

instance Data.Aeson.ToJSON SensorRequest
    where toJSON (SensorRequest a1
                                a2
                                a3
                                a4
                                a5) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "signature") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                      (,) (Data.Text.pack "time") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2,
                                                                                                                                      (,) (Data.Text.pack "expires") Data.Functor.<$> GHC.Base.fmap (Data.Aeson.Types.Number GHC.Base.. GHC.Num.fromInteger) a3,
                                                                                                                                      (,) (Data.Text.pack "username") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a4,
                                                                                                                                      (,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a5])