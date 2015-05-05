{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.ActuatorRequest where

import SSPL.Bindings.Instances ()

import Data.Binary (Binary)
import Data.Typeable
import GHC.Generics

import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Foldable
import Data.Functor
import Data.HashMap.Lazy
import Data.Map
import Data.Maybe
import Data.Text hiding (unlines)
import Data.Traversable
import Data.Tuple
import GHC.Base
import GHC.Classes
import GHC.List
import GHC.Show
import Prelude
import Text.Regex.Base.RegexLike

graph :: Data.Aeson.Schema.Types.Graph Data.Aeson.Schema.Types.Schema
                                       Data.Text.Text

graph = Data.Map.fromList [(Data.Text.pack "ActuatorRequest",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "sspl_ll_debug",
                                                                                                                                  Data.Aeson.Schema.Types.empty),
                                                                                                                                 (Data.Text.pack "actuator_request_type",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "thread_controller",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "module_name",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Identify the thread to be managed by its class name")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "thread_request",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Action to be applied to thread: start | stop | restart | status")})],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaAdditionalProperties = Data.Aeson.Schema.Choice.Choice1of2 Prelude.False}),
                                                                                                                                                                                                                                       (Data.Text.pack "logging",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "log_msg",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "The message to be logged")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "log_type",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Identify the type of log message")})],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaAdditionalProperties = Data.Aeson.Schema.Choice.Choice1of2 Prelude.False}),
                                                                                                                                                                                                                                       (Data.Text.pack "service_controller",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "service_name",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Identify the service to be managed")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "service_request",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Action to be applied to service: start | stop | restart | status")})],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaAdditionalProperties = Data.Aeson.Schema.Choice.Choice1of2 Prelude.False})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaAdditionalProperties = Data.Aeson.Schema.Choice.Choice1of2 Prelude.False,
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True}),
                                                                                                                                 (Data.Text.pack "sspl_ll_msg_header",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data ActuatorRequestActuator_request_typeThread_controller = ActuatorRequestActuator_request_typeThread_controller
  { actuatorRequestActuator_request_typeThread_controllerModule_name :: Data.Text.Text -- ^ Identify the thread to be managed by its class name
  , actuatorRequestActuator_request_typeThread_controllerThread_request :: Data.Text.Text -- ^ Action to be applied to thread: start | stop | restart | status
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorRequestActuator_request_typeThread_controller

instance Data.Aeson.FromJSON ActuatorRequestActuator_request_typeThread_controller
    where parseJSON (Data.Aeson.Types.Object obj) = do {let items = Data.HashMap.Lazy.toList obj
                                                         in Data.Foldable.forM_ items GHC.Base.$ (\(pname,
                                                                                                    value) -> do
                                                                                                                let matchingPatterns = GHC.List.filter (GHC.Base.flip Text.Regex.Base.RegexLike.match (Data.Text.unpack pname) GHC.Base.. (Data.Aeson.Schema.Types.patternCompiled GHC.Base.. Data.Tuple.fst)) [];
                                                                                                                Data.Foldable.forM_ matchingPatterns GHC.Base.$ (\(_,
                                                                                                                                                                   sch) -> do case Data.Aeson.Schema.Validator.validate graph sch value of
                                                                                                                                                                                  [] -> GHC.Base.return ()
                                                                                                                                                                                  es -> GHC.Base.fail GHC.Base.$ unlines es);
                                                                                                                let isAdditionalProperty = Data.Foldable.null matchingPatterns GHC.Classes.&& (pname `Data.Foldable.notElem` [Data.Text.pack "module_name",
                                                                                                                                                                                                                              Data.Text.pack "thread_request"]);
                                                                                                                GHC.Base.when isAdditionalProperty (GHC.Base.fail "additional properties are not allowed"));
                                                        (GHC.Base.pure ActuatorRequestActuator_request_typeThread_controller GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property module_name missing") (\val -> case val of
                                                                                                                                                                                                                                Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "module_name") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property thread_request missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                        Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                        _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_request") obj)}
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorRequestActuator_request_typeThread_controller
    where toJSON (ActuatorRequestActuator_request_typeThread_controller a1
                                                                        a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "module_name") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                              (,) (Data.Text.pack "thread_request") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorRequestActuator_request_typeLogging = ActuatorRequestActuator_request_typeLogging
  { actuatorRequestActuator_request_typeLoggingLog_msg :: Data.Text.Text -- ^ The message to be logged
  , actuatorRequestActuator_request_typeLoggingLog_type :: Data.Text.Text -- ^ Identify the type of log message
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorRequestActuator_request_typeLogging

instance Data.Aeson.FromJSON ActuatorRequestActuator_request_typeLogging
    where parseJSON (Data.Aeson.Types.Object obj) = do {let items_1 = Data.HashMap.Lazy.toList obj
                                                         in Data.Foldable.forM_ items_1 GHC.Base.$ (\(pname_1,
                                                                                                      value_1) -> do
                                                                                                                    let matchingPatterns_1 = GHC.List.filter (GHC.Base.flip Text.Regex.Base.RegexLike.match (Data.Text.unpack pname_1) GHC.Base.. (Data.Aeson.Schema.Types.patternCompiled GHC.Base.. Data.Tuple.fst)) [];
                                                                                                                    Data.Foldable.forM_ matchingPatterns_1 GHC.Base.$ (\(_,
                                                                                                                                                                         sch_1) -> do case Data.Aeson.Schema.Validator.validate graph sch_1 value_1 of
                                                                                                                                                                                          [] -> GHC.Base.return ()
                                                                                                                                                                                          es_1 -> GHC.Base.fail GHC.Base.$ unlines es_1);
                                                                                                                    let isAdditionalProperty_1 = Data.Foldable.null matchingPatterns_1 GHC.Classes.&& (pname_1 `Data.Foldable.notElem` [Data.Text.pack "log_msg",
                                                                                                                                                                                                                                        Data.Text.pack "log_type"]);
                                                                                                                    GHC.Base.when isAdditionalProperty_1 (GHC.Base.fail "additional properties are not allowed"));
                                                        (GHC.Base.pure ActuatorRequestActuator_request_typeLogging GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property log_msg missing") (\val -> case val of
                                                                                                                                                                                                                  Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                  _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "log_msg") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property log_type missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "log_type") obj)}
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorRequestActuator_request_typeLogging
    where toJSON (ActuatorRequestActuator_request_typeLogging a1
                                                              a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "log_msg") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                    (,) (Data.Text.pack "log_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorRequestActuator_request_typeService_controller = ActuatorRequestActuator_request_typeService_controller
  { actuatorRequestActuator_request_typeService_controllerService_name :: Data.Text.Text -- ^ Identify the service to be managed
  , actuatorRequestActuator_request_typeService_controllerService_request :: Data.Text.Text -- ^ Action to be applied to service: start | stop | restart | status
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorRequestActuator_request_typeService_controller

instance Data.Aeson.FromJSON ActuatorRequestActuator_request_typeService_controller
    where parseJSON (Data.Aeson.Types.Object obj) = do {let items_2 = Data.HashMap.Lazy.toList obj
                                                         in Data.Foldable.forM_ items_2 GHC.Base.$ (\(pname_2,
                                                                                                      value_2) -> do
                                                                                                                    let matchingPatterns_2 = GHC.List.filter (GHC.Base.flip Text.Regex.Base.RegexLike.match (Data.Text.unpack pname_2) GHC.Base.. (Data.Aeson.Schema.Types.patternCompiled GHC.Base.. Data.Tuple.fst)) [];
                                                                                                                    Data.Foldable.forM_ matchingPatterns_2 GHC.Base.$ (\(_,
                                                                                                                                                                         sch_2) -> do case Data.Aeson.Schema.Validator.validate graph sch_2 value_2 of
                                                                                                                                                                                          [] -> GHC.Base.return ()
                                                                                                                                                                                          es_2 -> GHC.Base.fail GHC.Base.$ unlines es_2);
                                                                                                                    let isAdditionalProperty_2 = Data.Foldable.null matchingPatterns_2 GHC.Classes.&& (pname_2 `Data.Foldable.notElem` [Data.Text.pack "service_name",
                                                                                                                                                                                                                                        Data.Text.pack "service_request"]);
                                                                                                                    GHC.Base.when isAdditionalProperty_2 (GHC.Base.fail "additional properties are not allowed"));
                                                        (GHC.Base.pure ActuatorRequestActuator_request_typeService_controller GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_name missing") (\val -> case val of
                                                                                                                                                                                                                                  Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                  _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_name") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_request missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                            _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_request") obj)}
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorRequestActuator_request_typeService_controller
    where toJSON (ActuatorRequestActuator_request_typeService_controller a1
                                                                         a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "service_name") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                               (,) (Data.Text.pack "service_request") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorRequestActuator_request_type = ActuatorRequestActuator_request_type
  { actuatorRequestActuator_request_typeThread_controller :: GHC.Base.Maybe ActuatorRequestActuator_request_typeThread_controller
  , actuatorRequestActuator_request_typeLogging :: GHC.Base.Maybe ActuatorRequestActuator_request_typeLogging
  , actuatorRequestActuator_request_typeService_controller :: GHC.Base.Maybe ActuatorRequestActuator_request_typeService_controller
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorRequestActuator_request_type

instance Data.Aeson.FromJSON ActuatorRequestActuator_request_type
    where parseJSON (Data.Aeson.Types.Object obj) = do {let items_3 = Data.HashMap.Lazy.toList obj
                                                         in Data.Foldable.forM_ items_3 GHC.Base.$ (\(pname_3,
                                                                                                      value_3) -> do
                                                                                                                    let matchingPatterns_3 = GHC.List.filter (GHC.Base.flip Text.Regex.Base.RegexLike.match (Data.Text.unpack pname_3) GHC.Base.. (Data.Aeson.Schema.Types.patternCompiled GHC.Base.. Data.Tuple.fst)) [];
                                                                                                                    Data.Foldable.forM_ matchingPatterns_3 GHC.Base.$ (\(_,
                                                                                                                                                                         sch_3) -> do case Data.Aeson.Schema.Validator.validate graph sch_3 value_3 of
                                                                                                                                                                                          [] -> GHC.Base.return ()
                                                                                                                                                                                          es_3 -> GHC.Base.fail GHC.Base.$ unlines es_3);
                                                                                                                    let isAdditionalProperty_3 = Data.Foldable.null matchingPatterns_3 GHC.Classes.&& (pname_3 `Data.Foldable.notElem` [Data.Text.pack "thread_controller",
                                                                                                                                                                                                                                        Data.Text.pack "logging",
                                                                                                                                                                                                                                        Data.Text.pack "service_controller"]);
                                                                                                                    GHC.Base.when isAdditionalProperty_3 (GHC.Base.fail "additional properties are not allowed"));
                                                        ((GHC.Base.pure ActuatorRequestActuator_request_type GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_controller") obj)) GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "logging") obj)) GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "service_controller") obj)}
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorRequestActuator_request_type
    where toJSON (ActuatorRequestActuator_request_type a1
                                                       a2
                                                       a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "thread_controller") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a1,
                                                                                                                                                             (,) (Data.Text.pack "logging") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a2,
                                                                                                                                                             (,) (Data.Text.pack "service_controller") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a3])

data ActuatorRequest = ActuatorRequest
  { actuatorRequestSspl_ll_debug :: GHC.Base.Maybe Data.Aeson.Types.Value
  , actuatorRequestActuator_request_type :: ActuatorRequestActuator_request_type
  , actuatorRequestSspl_ll_msg_header :: Data.Aeson.Types.Value
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorRequest

instance Data.Aeson.FromJSON ActuatorRequest
    where parseJSON (Data.Aeson.Types.Object obj) = do ((GHC.Base.pure ActuatorRequest GHC.Base.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                               [] -> GHC.Base.return ()
                                                                                                                                               es_4 -> GHC.Base.fail GHC.Base.$ unlines es_4);
                                                                                                                                           GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_debug") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property actuator_request_type missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "actuator_request_type") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property sspl_ll_msg_header missing") (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True} val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              [] -> GHC.Base.return ()
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              es_5 -> GHC.Base.fail GHC.Base.$ unlines es_5);
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                          GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_msg_header") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorRequest
    where toJSON (ActuatorRequest a1
                                  a2
                                  a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "sspl_ll_debug") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                        (,) (Data.Text.pack "actuator_request_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a2,
                                                                                                                                        (,) (Data.Text.pack "sspl_ll_msg_header") Data.Functor.<$> (GHC.Base.Just GHC.Base.. GHC.Base.id) a3])
