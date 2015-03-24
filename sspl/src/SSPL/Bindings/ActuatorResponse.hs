{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.ActuatorResponse where

import SSPL.Bindings.Instances

import Control.Applicative
import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Aeson.Types
import Data.Binary
import Data.Functor
import Data.HashMap.Lazy
import Data.List
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
import Text.Regex
import Text.Regex.PCRE.String

graph :: Data.Aeson.Schema.Types.Graph Data.Aeson.Schema.Types.Schema
                                       Data.Text.Text

graph = Data.Map.fromList [(Data.Text.pack "ActuatorResponse",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "sspl_ll_debug",
                                                                                                                                  Data.Aeson.Schema.Types.empty),
                                                                                                                                 (Data.Text.pack "actuator_response_type",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "systemd_service",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "service_response",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Response from action applied: start | stop | restart | status")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "service_name",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Identify the service to be managed")})]}),
                                                                                                                                                                                                                                       (Data.Text.pack "ack",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ack_msg",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Message describing acknowledgement")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "ack_type",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Identify the type of acknowledgement")})]}),
                                                                                                                                                                                                                                       (Data.Text.pack "thread_controller",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "module_name",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Identify the module to be managed by its class name")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "thread_response",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Response from action applied: start | stop | restart | status")})]})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True}),
                                                                                                                                 (Data.Text.pack "sspl_ll_msg_header",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaDSchema = Data.Maybe.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data ActuatorResponseActuator_response_typeSystemd_service = ActuatorResponseActuator_response_typeSystemd_service
  { actuatorResponseActuator_response_typeSystemd_serviceService_response :: Data.Text.Text -- ^ Response from action applied: start | stop | restart | status
  , actuatorResponseActuator_response_typeSystemd_serviceService_name :: Data.Text.Text -- ^ Identify the service to be managed
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_typeSystemd_service

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_typeSystemd_service
    where parseJSON (Data.Aeson.Types.Object obj) = do (Control.Applicative.pure ActuatorResponseActuator_response_typeSystemd_service Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_response missing") (\val -> case val of
                                                                                                                                                                                                                                                          Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                          _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_response") obj)) Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_name missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_name") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_typeSystemd_service
    where toJSON (ActuatorResponseActuator_response_typeSystemd_service a1
                                                                        a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "service_response") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                              (,) (Data.Text.pack "service_name") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseActuator_response_typeAck = ActuatorResponseActuator_response_typeAck
  { actuatorResponseActuator_response_typeAckAck_msg :: Data.Text.Text -- ^ Message describing acknowledgement
  , actuatorResponseActuator_response_typeAckAck_type :: Data.Text.Text -- ^ Identify the type of acknowledgement
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_typeAck

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_typeAck
    where parseJSON (Data.Aeson.Types.Object obj) = do (Control.Applicative.pure ActuatorResponseActuator_response_typeAck Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property ack_msg missing") (\val -> case val of
                                                                                                                                                                                                                                     Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                     _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "ack_msg") obj)) Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property ack_type missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                              _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "ack_type") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_typeAck
    where toJSON (ActuatorResponseActuator_response_typeAck a1
                                                            a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ack_msg") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                  (,) (Data.Text.pack "ack_type") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseActuator_response_typeThread_controller = ActuatorResponseActuator_response_typeThread_controller
  { actuatorResponseActuator_response_typeThread_controllerModule_name :: Data.Text.Text -- ^ Identify the module to be managed by its class name
  , actuatorResponseActuator_response_typeThread_controllerThread_response :: Data.Text.Text -- ^ Response from action applied: start | stop | restart | status
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_typeThread_controller

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_typeThread_controller
    where parseJSON (Data.Aeson.Types.Object obj) = do (Control.Applicative.pure ActuatorResponseActuator_response_typeThread_controller Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property module_name missing") (\val -> case val of
                                                                                                                                                                                                                                                       Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                       _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "module_name") obj)) Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property thread_response missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                           Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                                           _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_response") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_typeThread_controller
    where toJSON (ActuatorResponseActuator_response_typeThread_controller a1
                                                                          a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "module_name") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                                (,) (Data.Text.pack "thread_response") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseActuator_response_type = ActuatorResponseActuator_response_type
  { actuatorResponseActuator_response_typeSystemd_service :: Data.Maybe.Maybe ActuatorResponseActuator_response_typeSystemd_service
  , actuatorResponseActuator_response_typeAck :: Data.Maybe.Maybe ActuatorResponseActuator_response_typeAck
  , actuatorResponseActuator_response_typeThread_controller :: Data.Maybe.Maybe ActuatorResponseActuator_response_typeThread_controller
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_type

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_type
    where parseJSON (Data.Aeson.Types.Object obj) = do ((Control.Applicative.pure ActuatorResponseActuator_response_type Control.Applicative.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "systemd_service") obj)) Control.Applicative.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "ack") obj)) Control.Applicative.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_controller") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_type
    where toJSON (ActuatorResponseActuator_response_type a1
                                                         a2
                                                         a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "systemd_service") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a1,
                                                                                                                                                               (,) (Data.Text.pack "ack") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a2,
                                                                                                                                                               (,) (Data.Text.pack "thread_controller") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a3])

data ActuatorResponse = ActuatorResponse
  { actuatorResponseSspl_ll_debug :: Data.Maybe.Maybe Data.Aeson.Types.Value
  , actuatorResponseActuator_response_type :: ActuatorResponseActuator_response_type
  , actuatorResponseSspl_ll_msg_header :: Data.Aeson.Types.Value
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponse

instance Data.Aeson.FromJSON ActuatorResponse
    where parseJSON (Data.Aeson.Types.Object obj) = do ((Control.Applicative.pure ActuatorResponse Control.Applicative.<*> Data.Traversable.traverse (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty val of
                                                                                                                                                                      [] -> GHC.Base.return ()
                                                                                                                                                                      es -> GHC.Base.fail GHC.Base.$ Data.List.unlines es);
                                                                                                                                                                  GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_debug") obj)) Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property actuator_response_type missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "actuator_response_type") obj)) Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property sspl_ll_msg_header missing") (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True} val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             [] -> GHC.Base.return ()
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             es_1 -> GHC.Base.fail GHC.Base.$ Data.List.unlines es_1);
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_msg_header") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponse
    where toJSON (ActuatorResponse a1
                                   a2
                                   a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "sspl_ll_debug") Data.Functor.<$> GHC.Base.fmap GHC.Base.id a1,
                                                                                                                                         (,) (Data.Text.pack "actuator_response_type") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.toJSON) a2,
                                                                                                                                         (,) (Data.Text.pack "sspl_ll_msg_header") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. GHC.Base.id) a3])
