{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.ActuatorResponse where

import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Aeson.Types
import Data.Binary
import Data.Either
import Data.Functor
import Data.HashMap.Lazy
import Data.Hashable
import Data.Map
import Data.Maybe
import Data.Ratio
import Data.Scientific
import Data.Text
import Data.Traversable
import Data.Typeable
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

graph = Data.Map.fromList [(Data.Text.pack "ActuatorResponse",
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
                                                                                                                                                                Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "The number of seconds the signature remains valid after being generated")}),
                                                                                                                                 (Data.Text.pack "username",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                Data.Aeson.Schema.Types.schemaDescription = GHC.Base.Just (Data.Text.pack "Username who generated message")}),
                                                                                                                                 (Data.Text.pack "message",
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
                                                                                                                                                                Data.Aeson.Schema.Types.schemaRequired = Prelude.True})],
                                                          Data.Aeson.Schema.Types.schemaId = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#"),
                                                          Data.Aeson.Schema.Types.schemaDSchema = GHC.Base.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data ActuatorResponseMessageActuator_response_typeAck = ActuatorResponseMessageActuator_response_typeAck
  { actuatorResponseMessageActuator_response_typeAckAck_msg :: Data.Text.Text -- ^ Message describing acknowledgement
  , actuatorResponseMessageActuator_response_typeAckAck_type :: Data.Text.Text -- ^ Identify the type of acknowledgement
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ActuatorResponseMessageActuator_response_typeAck

instance Data.Hashable.Hashable ActuatorResponseMessageActuator_response_typeAck

instance Data.Aeson.FromJSON ActuatorResponseMessageActuator_response_typeAck
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponseMessageActuator_response_typeAck GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property ack_msg missing") (\val -> case val of
                                                                                                                                                                                                                      Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                      _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "ack_msg") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property ack_type missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                    Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                    _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "ack_type") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseMessageActuator_response_typeAck
    where toJSON (ActuatorResponseMessageActuator_response_typeAck a1
                                                                   a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ack_msg") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                         (,) (Data.Text.pack "ack_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseMessageActuator_response_typeThread_controller = ActuatorResponseMessageActuator_response_typeThread_controller
  { actuatorResponseMessageActuator_response_typeThread_controllerModule_name :: Data.Text.Text -- ^ Identify the module to be managed by its class name
  , actuatorResponseMessageActuator_response_typeThread_controllerThread_response :: Data.Text.Text -- ^ Response from action applied: start | stop | restart | status
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ActuatorResponseMessageActuator_response_typeThread_controller

instance Data.Hashable.Hashable ActuatorResponseMessageActuator_response_typeThread_controller

instance Data.Aeson.FromJSON ActuatorResponseMessageActuator_response_typeThread_controller
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponseMessageActuator_response_typeThread_controller GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property module_name missing") (\val -> case val of
                                                                                                                                                                                                                                        Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                        _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "module_name") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property thread_response missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                 Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                 _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_response") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseMessageActuator_response_typeThread_controller
    where toJSON (ActuatorResponseMessageActuator_response_typeThread_controller a1
                                                                                 a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "module_name") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                                       (,) (Data.Text.pack "thread_response") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseMessageActuator_response_typeService_controller = ActuatorResponseMessageActuator_response_typeService_controller
  { actuatorResponseMessageActuator_response_typeService_controllerService_response :: Data.Text.Text -- ^ Response from action applied: start | stop | restart | status
  , actuatorResponseMessageActuator_response_typeService_controllerService_name :: Data.Text.Text -- ^ Identify the service to be managed
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ActuatorResponseMessageActuator_response_typeService_controller

instance Data.Hashable.Hashable ActuatorResponseMessageActuator_response_typeService_controller

instance Data.Aeson.FromJSON ActuatorResponseMessageActuator_response_typeService_controller
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponseMessageActuator_response_typeService_controller GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_response missing") (\val -> case val of
                                                                                                                                                                                                                                              Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                              _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_response") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property service_name missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                         Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                         _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "service_name") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseMessageActuator_response_typeService_controller
    where toJSON (ActuatorResponseMessageActuator_response_typeService_controller a1
                                                                                  a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "service_response") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                                                                        (,) (Data.Text.pack "service_name") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2])

data ActuatorResponseMessageActuator_response_type = ActuatorResponseMessageActuator_response_type
  { actuatorResponseMessageActuator_response_typeAck :: GHC.Base.Maybe ActuatorResponseMessageActuator_response_typeAck
  , actuatorResponseMessageActuator_response_typeThread_controller :: GHC.Base.Maybe ActuatorResponseMessageActuator_response_typeThread_controller
  , actuatorResponseMessageActuator_response_typeService_controller :: GHC.Base.Maybe ActuatorResponseMessageActuator_response_typeService_controller
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ActuatorResponseMessageActuator_response_type

instance Data.Hashable.Hashable ActuatorResponseMessageActuator_response_type

instance Data.Aeson.FromJSON ActuatorResponseMessageActuator_response_type
    where parseJSON (Data.Aeson.Types.Object obj) = do ((GHC.Base.pure ActuatorResponseMessageActuator_response_type GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "ack") obj)) GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "thread_controller") obj)) GHC.Base.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "service_controller") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseMessageActuator_response_type
    where toJSON (ActuatorResponseMessageActuator_response_type a1
                                                                a2
                                                                a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "ack") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a1,
                                                                                                                                                                      (,) (Data.Text.pack "thread_controller") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a2,
                                                                                                                                                                      (,) (Data.Text.pack "service_controller") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a3])

data ActuatorResponseMessage = ActuatorResponseMessage
  { actuatorResponseMessageActuator_response_type :: ActuatorResponseMessageActuator_response_type
  , actuatorResponseMessageSspl_ll_msg_header :: Data.Aeson.Types.Value
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ActuatorResponseMessage

instance Data.Hashable.Hashable ActuatorResponseMessage

instance Data.Aeson.FromJSON ActuatorResponseMessage
    where parseJSON (Data.Aeson.Types.Object obj) = do (GHC.Base.pure ActuatorResponseMessage GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property actuator_response_type missing") Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "actuator_response_type") obj)) GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property sspl_ll_msg_header missing") (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True} val of
                                                                                                                                                                                                                                                                                                                                                                                                             [] -> GHC.Base.return ()
                                                                                                                                                                                                                                                                                                                                                                                                             es -> GHC.Base.fail GHC.Base.$ Prelude.unlines es);
                                                                                                                                                                                                                                                                                                                                                                                                        GHC.Base.return val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "sspl_ll_msg_header") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON ActuatorResponseMessage
    where toJSON (ActuatorResponseMessage a1
                                          a2) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "actuator_response_type") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a1,
                                                                                                                                                (,) (Data.Text.pack "sspl_ll_msg_header") Data.Functor.<$> (GHC.Base.Just GHC.Base.. GHC.Base.id) a2])

data ActuatorResponse = ActuatorResponse
  { actuatorResponseSignature :: Data.Text.Text -- ^ Authentication signature of message
  , actuatorResponseTime :: Data.Text.Text -- ^ The time the signature was generated
  , actuatorResponseExpires :: GHC.Base.Maybe Prelude.Integer -- ^ The number of seconds the signature remains valid after being generated
  , actuatorResponseUsername :: Data.Text.Text -- ^ Username who generated message
  , actuatorResponseMessage :: ActuatorResponseMessage
  } deriving (GHC.Classes.Eq, GHC.Show.Show, GHC.Generics.Generic, Data.Typeable.Typeable)


instance Data.Binary.Binary ActuatorResponse

instance Data.Hashable.Hashable ActuatorResponse

instance Data.Aeson.FromJSON ActuatorResponse
    where parseJSON (Data.Aeson.Types.Object obj) = do ((((GHC.Base.pure ActuatorResponse GHC.Base.<*> Data.Maybe.maybe (GHC.Base.fail "required property signature missing") (\val -> case val of
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

instance Data.Aeson.ToJSON ActuatorResponse
    where toJSON (ActuatorResponse a1
                                   a2
                                   a3
                                   a4
                                   a5) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "signature") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a1,
                                                                                                                                         (,) (Data.Text.pack "time") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a2,
                                                                                                                                         (,) (Data.Text.pack "expires") Data.Functor.<$> GHC.Base.fmap (Data.Aeson.Types.Number GHC.Base.. GHC.Num.fromInteger) a3,
                                                                                                                                         (,) (Data.Text.pack "username") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.Types.String) a4,
                                                                                                                                         (,) (Data.Text.pack "message") Data.Functor.<$> (GHC.Base.Just GHC.Base.. Data.Aeson.toJSON) a5])