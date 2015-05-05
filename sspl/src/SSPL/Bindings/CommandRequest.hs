{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE StandaloneDeriving #-}

module SSPL.Bindings.CommandRequest where

import SSPL.Bindings.Instances ()

import Data.Binary (Binary)
import Data.Typeable
import GHC.Generics

import Control.Applicative
import Control.Monad
import Data.Aeson
import Data.Aeson.Schema.Choice
import Data.Aeson.Schema.Types
import Data.Aeson.Schema.Validator
import Data.Aeson.Types
import Data.Functor
import Data.HashMap.Lazy
import Data.List
import Data.Map
import Data.Maybe
import Data.Text
import Data.Traversable
import GHC.Base
import GHC.Classes
import GHC.List
import GHC.Show
import Prelude

graph :: Data.Aeson.Schema.Types.Graph Data.Aeson.Schema.Types.Schema
                                       Data.Text.Text

graph = Data.Map.fromList [(Data.Text.pack "CommandRequest",
                            Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                          Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "serviceRequest",
                                                                                                                                  Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.ObjectType],
                                                                                                                                                                Data.Aeson.Schema.Types.schemaProperties = Data.HashMap.Lazy.fromList [(Data.Text.pack "command",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaEnum = Data.Maybe.Just [Data.Aeson.Types.String (Data.Text.pack "start"),
                                                                                                                                                                                                                                                                                                                            Data.Aeson.Types.String (Data.Text.pack "stop"),
                                                                                                                                                                                                                                                                                                                            Data.Aeson.Types.String (Data.Text.pack "restart"),
                                                                                                                                                                                                                                                                                                                            Data.Aeson.Types.String (Data.Text.pack "enable"),
                                                                                                                                                                                                                                                                                                                            Data.Aeson.Types.String (Data.Text.pack "disable"),
                                                                                                                                                                                                                                                                                                                            Data.Aeson.Types.String (Data.Text.pack "status")]}),
                                                                                                                                                                                                                                       (Data.Text.pack "serviceName",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Name of the service to control.")}),
                                                                                                                                                                                                                                       (Data.Text.pack "nodes",
                                                                                                                                                                                                                                        Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaType = [Data.Aeson.Schema.Choice.Choice1of2 Data.Aeson.Schema.Types.StringType],
                                                                                                                                                                                                                                                                      Data.Aeson.Schema.Types.schemaDescription = Data.Maybe.Just (Data.Text.pack "Regex on node FQDNs. If not specified, applies to all nodes.")})]})],
                                                          Data.Aeson.Schema.Types.schemaDSchema = Data.Maybe.Just (Data.Text.pack "http://json-schema.org/draft-03/schema#")})]

data CommandRequestServiceRequest = CommandRequestServiceRequest
  { commandRequestServiceRequestCommand :: Data.Aeson.Types.Value
  , commandRequestServiceRequestServiceName :: Data.Text.Text -- ^ Name of the service to control.
  , commandRequestServiceRequestNodes :: Data.Maybe.Maybe Data.Text.Text -- ^ Regex on node FQDNs. If not specified, applies to all nodes.
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary CommandRequestServiceRequest

instance Data.Aeson.FromJSON CommandRequestServiceRequest
    where parseJSON (Data.Aeson.Types.Object obj) = do ((Control.Applicative.pure CommandRequestServiceRequest Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property command missing") (\val -> do {Control.Monad.unless (val `GHC.List.elem` [Data.Aeson.Types.String (Data.Text.pack "start"),
                                                                                                                                                                                                                                                                    Data.Aeson.Types.String (Data.Text.pack "stop"),
                                                                                                                                                                                                                                                                    Data.Aeson.Types.String (Data.Text.pack "restart"),
                                                                                                                                                                                                                                                                    Data.Aeson.Types.String (Data.Text.pack "enable"),
                                                                                                                                                                                                                                                                    Data.Aeson.Types.String (Data.Text.pack "disable"),
                                                                                                                                                                                                                                                                    Data.Aeson.Types.String (Data.Text.pack "status")]) (GHC.Base.fail "not one of the values in enum");
                                                                                                                                                                                                                         (\val -> do {(case Data.Aeson.Schema.Validator.validate graph Data.Aeson.Schema.Types.empty{Data.Aeson.Schema.Types.schemaRequired = Prelude.True,
                                                                                                                                                                                                                                                                                                                    Data.Aeson.Schema.Types.schemaEnum = Data.Maybe.Just [Data.Aeson.Types.String (Data.Text.pack "start"),
                                                                                                                                                                                                                                                                                                                                                                          Data.Aeson.Types.String (Data.Text.pack "stop"),
                                                                                                                                                                                                                                                                                                                                                                          Data.Aeson.Types.String (Data.Text.pack "restart"),
                                                                                                                                                                                                                                                                                                                                                                          Data.Aeson.Types.String (Data.Text.pack "enable"),
                                                                                                                                                                                                                                                                                                                                                                          Data.Aeson.Types.String (Data.Text.pack "disable"),
                                                                                                                                                                                                                                                                                                                                                                          Data.Aeson.Types.String (Data.Text.pack "status")]} val of
                                                                                                                                                                                                                                          [] -> GHC.Base.return ()
                                                                                                                                                                                                                                          es -> GHC.Base.fail GHC.Base.$ Data.List.unlines es);
                                                                                                                                                                                                                                      GHC.Base.return val}) val}) (Data.HashMap.Lazy.lookup (Data.Text.pack "command") obj)) Control.Applicative.<*> Data.Maybe.maybe (GHC.Base.fail "required property serviceName missing") (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                           Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                           _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "serviceName") obj)) Control.Applicative.<*> Data.Traversable.traverse (\val -> case val of
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            Data.Aeson.Types.String str -> do GHC.Base.return str
                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            _ -> GHC.Base.fail "not a string") (Data.HashMap.Lazy.lookup (Data.Text.pack "nodes") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON CommandRequestServiceRequest
    where toJSON (CommandRequestServiceRequest a1
                                               a2
                                               a3) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "command") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. GHC.Base.id) a1,
                                                                                                                                                     (,) (Data.Text.pack "serviceName") Data.Functor.<$> (Data.Maybe.Just GHC.Base.. Data.Aeson.Types.String) a2,
                                                                                                                                                     (,) (Data.Text.pack "nodes") Data.Functor.<$> GHC.Base.fmap Data.Aeson.Types.String a3])

data CommandRequest = CommandRequest
  { commandRequestServiceRequest :: Data.Maybe.Maybe CommandRequestServiceRequest
  } deriving (GHC.Classes.Eq, GHC.Show.Show, Generic, Typeable)

instance Binary CommandRequest

instance Data.Aeson.FromJSON CommandRequest
    where parseJSON (Data.Aeson.Types.Object obj) = do Control.Applicative.pure CommandRequest Control.Applicative.<*> Data.Traversable.traverse Data.Aeson.parseJSON (Data.HashMap.Lazy.lookup (Data.Text.pack "serviceRequest") obj)
          parseJSON _ = GHC.Base.fail "not an object"

instance Data.Aeson.ToJSON CommandRequest
    where toJSON (CommandRequest a1) = Data.Aeson.Types.Object GHC.Base.$ (Data.HashMap.Lazy.fromList GHC.Base.$ Data.Maybe.catMaybes [(,) (Data.Text.pack "serviceRequest") Data.Functor.<$> GHC.Base.fmap Data.Aeson.toJSON a1])
