{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.ActuatorResponse where

import SSPL.Bindings.Instances ()

import Data.Binary (Binary)
import Data.Typeable
import GHC.Generics

import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Functor
import Data.HashMap.Lazy
import Data.Map
import Data.Maybe
import Data.Text hiding (unlines)
import Data.Traversable
import GHC.Base
import GHC.Classes
import GHC.Show
import Prelude

graph :: Data.Aeson.Schema.Types.Graph Data.Aeson.Schema.Types.Schema
                                       Data.Text.Text

graph = Data.Map.fromList [(Data.Text.pack "ActuatorResponse",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "actuator_response_type",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ack",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "ack_msg",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Message describing acknowledgement")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "ack_type",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Identify the type of acknowledgement")})]}),
                                                                                                                                                                                                                                       (Data.Text.pack "thread_controller",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "module_name",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Identify the module to be managed by its class name")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "thread_response",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Response from action applied: start | stop | restart | status")})]}),
                                                                                                                                                                                                                                       (Data.Text.pack "service_controller",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "service_response",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Response from action applied: start | stop | restart | status")}),
                                                                                                                                                                                                                                                                                                                                             (Data.Text.pack "service_name",
                                                                                                                                                                                                                                                                                                                                              Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Identify the service to be managed")})]})],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True}),
                                                                                                                                 (Data.Text.pack "sspl_ll_msg_header",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data ActuatorResponseActuator_response_typeAck = ActuatorResponseActuator_response_typeAck
  { actuatorResponseActuator_response_typeAckAck_msg :: Data.Text.Text -- ^ Message describing acknowledgement
  , actuatorResponseActuator_response_typeAckAck_type :: Data.Text.Text -- ^ Identify the type of acknowledgement
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_typeAck

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_typeAck
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponseActuator_response_typeAck GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property ack_msg missing") (\val -> case val of
                                                                                                                                                                                                               Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                               _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "ack_msg") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property ack_type missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                             Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                             _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "ack_type") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_typeAck
    where toJSON (ActuatorResponseActuator_response_typeAck a1
                                                            a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ack_msg") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                  (,) (Data.Text.pack "ack_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseActuator_response_typeThread_controller = ActuatorResponseActuator_response_typeThread_controller
  { actuatorResponseActuator_response_typeThread_controllerModule_name :: Data.Text.Text -- ^ Identify the module to be managed by its class name
  , actuatorResponseActuator_response_typeThread_controllerThread_response :: Data.Text.Text -- ^ Response from action applied: start | stop | restart | status
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_typeThread_controller

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_typeThread_controller
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponseActuator_response_typeThread_controller GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property module_name missing") (\val -> case val of
                                                                                                                                                                                                                                 Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                 _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "module_name") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property thread_response missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                          Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                          _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_response") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_typeThread_controller
    where toJSON (ActuatorResponseActuator_response_typeThread_controller a1
                                                                          a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "module_name") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                                (,) (Data.Text.pack "thread_response") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseActuator_response_typeService_controller = ActuatorResponseActuator_response_typeService_controller
  { actuatorResponseActuator_response_typeService_controllerService_response :: Data.Text.Text -- ^ Response from action applied: start | stop | restart | status
  , actuatorResponseActuator_response_typeService_controllerService_name :: Data.Text.Text -- ^ Identify the service to be managed
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_typeService_controller

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_typeService_controller
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponseActuator_response_typeService_controller GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_response missing") (\val -> case val of
                                                                                                                                                                                                                                       Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                       _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_response") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_name missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                  Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                  _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_name") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_typeService_controller
    where toJSON (ActuatorResponseActuator_response_typeService_controller a1
                                                                           a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "service_response") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                                 (,) (Data.Text.pack "service_name") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseActuator_response_type = ActuatorResponseActuator_response_type
  { actuatorResponseActuator_response_typeAck :: GHC.Base.Maybe ActuatorResponseActuator_response_typeAck
  , actuatorResponseActuator_response_typeThread_controller :: GHC.Base.Maybe ActuatorResponseActuator_response_typeThread_controller
  , actuatorResponseActuator_response_typeService_controller :: GHC.Base.Maybe ActuatorResponseActuator_response_typeService_controller
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponseActuator_response_type

instance Data.Aeson.FromJSON ActuatorResponseActuator_response_type
    where parseJSON (Data.Aeson.Types.Object obj) = do ((GHC.Base.pure ActuatorResponseActuator_response_type GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "ack") obj)) GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_controller") obj)) GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "service_controller") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseActuator_response_type
    where toJSON (ActuatorResponseActuator_response_type a1
                                                         a2
                                                         a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ack") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a1,
                                                                                                                                                               (,) (Data.Text.pack "thread_controller") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a2,
                                                                                                                                                               (,) (Data.Text.pack "service_controller") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a3])

data ActuatorResponse = ActuatorResponse
  { actuatorResponseActuator_response_type :: ActuatorResponseActuator_response_type
  , actuatorResponseSspl_ll_msg_header :: Data.Aeson.Types.Value
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary ActuatorResponse

instance Data.Aeson.FromJSON ActuatorResponse
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponse GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property actuator_response_type missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "actuator_response_type") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property sspl_ll_msg_header missing") (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True} val of
                                                                                                                                                                                                                                                                                                                                                                                                     [] -> GHC.Base.return ()
                                                                                                                                                                                                                                                                                                                                                                                                     es -> GHC.Base.fail GHC.Base.$ unlines es);
                                                                                                                                                                                                                                                                                                                                                                                                 GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_msg_header") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponse
    where toJSON (ActuatorResponse a1
                                   a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "actuator_response_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a1,
                                                                                                                                         (,) (Data.Text.pack "sspl_ll_msg_header") Data.Functor.<$> (GHC.Base.Just GHC.Base.. GHC.Base.id) a2])
