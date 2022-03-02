{-# LANGUAGE StandaloneDeriving    #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE ViewPatterns          #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE DataKinds #-}
-- |
-- Module    : HA.Services.Ekg.Types
-- Copryight : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- EKG service types. In general you should not need to import this
-- module: import "HA.Services.Ekg" or "HA.Services.Ekg.RC" instead.
module HA.Services.Ekg.Types
  ( -- * Core service things
    EkgConf(..)
  , EkgState(..)
  , interface
    -- * Metrics
  , CounterCmd(..)
  , CounterContent(..)
  , DistributionCmd(..)
  , DistributionContent(..)
  , DistributionStats(..)
  , EkgMetric(..)
  , GaugeCmd(..)
  , GaugeContent(..)
  , LabelCmd(..)
  , LabelContent(..)
  , ModifyMetric(..)
  , runModifyMetric
    -- * Generated things
  , configDictEkgConf
  , configDictEkgConf__static
  , __remoteTable
  , HA.Services.Ekg.Types.__resourcesTable
  ) where

import           Control.Distributed.Process
import           Data.Foldable (for_)
import           Data.Hashable
import           Data.Int (Int64)
import qualified Data.Map as M
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Data.Typeable
import           GHC.Generics
import           HA.Aeson
import           HA.SafeCopy
import           HA.Service hiding (__remoteTable)
import           HA.Service.Interface
import           HA.Service.TH
import           Options.Schema
import           Options.Schema.Builder
import qualified System.Metrics.Counter as Counter
import qualified System.Metrics.Distribution as Distribution
import qualified System.Metrics.Gauge as Gauge
import qualified System.Metrics.Label as Label
import           System.Remote.Monitoring
import           Text.Printf

-- | Service configuration
data EkgConf = EkgConf
  { _ekg_host :: String
  , _ekg_port :: !Int
  } deriving (Eq, Show, Generic)

instance Hashable EkgConf
instance ToJSON EkgConf

-- | Service schema
ekgSchema :: Schema EkgConf
ekgSchema = EkgConf <$> host <*> port
  where
    host = strOption
         $ long "listen"
        <> short 'l'
        <> metavar "ADDRESS"
        <> summary "Host to listen on"
        <> value "localhost"
    port = intOption
         $ long "port"
        <> short 'p'
        <> metavar "PORT"
        <> summary "Port to listen on"
        <> value 8000

instance StorageIndex EkgConf where
   typeKey _ = $(mkUUID "727a2a2d-9582-4bef-8051-8e153fe57642")
instance StorageIndex (Service EkgConf) where
   typeKey _ = $(mkUUID "11aec90e-c247-4bca-9d7d-240670ea544a")
$(generateDicts ''EkgConf)
$(deriveService ''EkgConf 'ekgSchema [])
deriveSafeCopy 0 'base ''EkgConf

-- | A reply to various metric read requests. All replies sent to the
-- RC.
data MetricReadReply
  = GaugeReadReply !GaugeContent
  | CounterReadReply !CounterContent
  | LabelReadReply !LabelContent
  | DistributionReadReply !DistributionContent
  deriving (Show, Generic, Typeable)

interface :: Interface ModifyMetric MetricReadReply
interface = Interface
  { ifVersion = 0
  , ifServiceName = "ekg"
  , ifEncodeToSvc = \_v -> Just . safeEncode interface
  , ifDecodeToSvc = safeDecode
  , ifEncodeFromSvc = \_v -> Just . safeEncode interface
  , ifDecodeFromSvc = safeDecode
  }

instance HasInterface EkgConf where
  type ToSvc EkgConf = ModifyMetric
  type FromSvc EkgConf = MetricReadReply
  getInterface _ = interface

-- | Service state
data EkgState = EkgState
  { _ekg_server :: Server
  -- ^ EKG-internal state
  , _ekg_metrics :: M.Map T.Text EkgMetric
  -- ^ EKG metrics live in the same namespace so keep them together.
  -- This way we can make sure we don't try to create two metrics with
  -- the same name anyway.
  }

-- | All types of metrics we can work with.
data EkgMetric = EkgCounter Counter.Counter
               | EkgDistribution Distribution.Distribution
               | EkgGauge Gauge.Gauge
               | EkgLabel Label.Label
  deriving (Typeable, Generic)

-- | Messages requesting metric changes.
data ModifyMetric = ModifyCounter String !CounterCmd
                  | ModifyDistribution String !DistributionCmd
                  | ModifyGauge String !GaugeCmd
                  | ModifyLabel String !LabelCmd
  deriving (Show, Eq, Ord, Typeable, Generic)

-- | Run an action described by 'ModifyMetric'.
runModifyMetric :: EkgState -> ModifyMetric -> Process EkgState
runModifyMetric st (ModifyCounter s cmd) = runModifyCounter st s cmd
runModifyMetric st (ModifyDistribution s cmd) = runModifyDistribution st s cmd
runModifyMetric st (ModifyGauge s cmd) = runModifyGauge st s cmd
runModifyMetric st (ModifyLabel s cmd) = runModifyLabel st s cmd

-- | Report on the type of underlying 'EkgMetric'. Used for debug message.
metricToType :: EkgMetric -> TypeRep
metricToType (EkgCounter c) = typeOf c
metricToType (EkgDistribution d) = typeOf d
metricToType (EkgGauge g) = typeOf g
metricToType (EkgLabel l) = typeOf l

-- | We were expecting one type of metric but found another, report it.
unexpectedType :: Typeable a
               => T.Text -- ^ Metric name
               -> Proxy a -- ^ Expected metric type
               -> EkgMetric -- ^ Metric we actually extracted
               -> String
unexpectedType n t m =
  printf "Expected EKG metric “%s” with type %s but found type %s instead"
         (T.unpack n) (show $ typeRep t) (show $ metricToType m)

-- * Metrics and their actions

-- | Actions we can perform on 'Gauge.Gauge's.
data GaugeCmd = GaugeRead
              -- ^ Corresponds to 'Gauge.read'. RC should listen for
              -- 'GaugeReadReply'.
              | GaugeInc
              -- ^ Corresponds to 'Gauge.inc'.
              | GaugeDec
              -- ^ Corresponds to 'Gauge.dec'.
              | GaugeAdd !Int64
              -- ^ Corresponds to 'Gauge.add'.
              | GaugeSubtract !Int64
              -- ^ Corresponds to 'Gauge.subtract'.
              | GaugeSet !Int64
              -- ^ Corresponds to 'Gauge.set'.
  deriving (Show, Eq, Ord, Generic, Typeable)

-- | A reply to the RC of 'GaugeRead'.
data GaugeContent = GaugeContent
  { _gc_name :: !T.Text
  -- ^ 'Gauge.Gauge' metric name
  , _gc_content :: !Int64
  -- ^ 'Gauge.Gauge' metric content
  } deriving (Show, Eq, Ord, Generic, Typeable)

-- | Run a 'GaugeCmd' on the specified metric.
runModifyGauge :: EkgState -> String -> GaugeCmd -> Process EkgState
runModifyGauge st (T.pack -> n) cmd  = do
  (st', m) <- case M.lookup n $ _ekg_metrics st of
    Just (EkgGauge g) -> return (st, Right g)
    Just m -> let wanted = Proxy :: Proxy Gauge.Gauge
              in return (st, Left $ unexpectedType n wanted m)
    Nothing -> do
      g <- liftIO $ getGauge n (_ekg_server st)
      let st' = st { _ekg_metrics = M.insert n (EkgGauge g) $ _ekg_metrics st }
      return (st', Right g)
  mreply <- case m of
    Left err -> say err >> return Nothing
    Right g -> liftIO $ case cmd of
      GaugeRead -> do
        i <- Gauge.read g
        return . Just . GaugeReadReply $! GaugeContent n i
      GaugeInc -> Gauge.inc g >> return Nothing
      GaugeDec -> Gauge.dec g >> return Nothing
      GaugeAdd i -> Gauge.add g i >> return Nothing
      GaugeSubtract i -> Gauge.subtract g i >> return Nothing
      GaugeSet i -> Gauge.set g i >> return Nothing

  for_ mreply $ sendRC interface
  return st'

-- | Actions we can perform on 'Counter.Counter's.
data CounterCmd = CounterRead
                -- ^ Corresponds to 'Counter.read'. RC should
                -- listen for 'CounterReadReply'.
                | CounterInc
                -- ^ Corresponds to 'Counter.inc'.
                | CounterAdd !Int64
                -- ^ Corresponds to 'Counter.add'.
  deriving (Show, Eq, Ord, Generic, Typeable)

-- | A reply sent to the RC of 'CounterRead'.
data CounterContent = CounterContent
  { _cc_name :: !T.Text
  -- ^ 'Counter.Counter' metric name.
  , _cc_content :: !Int64
  -- ^ 'Counter.Counter' metric content.
  } deriving (Show, Eq, Ord, Generic, Typeable)

-- | Run a 'CounterCmd' on the specified metric.
runModifyCounter :: EkgState -> String -> CounterCmd -> Process EkgState
runModifyCounter st (T.pack -> n) cmd  = do
  (st', m) <- case M.lookup n $ _ekg_metrics st of
    Just (EkgCounter c) -> return (st, Right c)
    Just m -> let wanted = Proxy :: Proxy Counter.Counter
              in return (st, Left $ unexpectedType n wanted m)
    Nothing -> do
      c <- liftIO $ getCounter n (_ekg_server st)
      let oldMap = _ekg_metrics st
          st' = st { _ekg_metrics = M.insert n (EkgCounter c) oldMap }
      return (st', Right c)
  mreply <- case m of
    Left err -> say err >> return Nothing
    Right c -> liftIO $ case cmd of
      CounterRead -> do
        i <- Counter.read c
        return . Just . CounterReadReply $! CounterContent n i
      CounterInc -> Counter.inc c >> return Nothing
      CounterAdd i -> Counter.add c i >> return Nothing
  for_ mreply $ sendRC interface
  return st'

-- | Actions we can perform on 'Label.Label's.
data LabelCmd = LabelSet !T.Text
              -- ^ Corresponds to 'Label.set'.
              | LabelRead
              -- ^ Corresponds to 'Label.read'. RC should listen
              -- for 'LabelReadReply'.
  deriving (Show, Eq, Ord, Generic, Typeable)

-- | A reply sent to the RC for 'LabelRead'.
data LabelContent = LabelContent
  { _lc_name :: !T.Text
  -- ^ 'Label.Label' metric name.
  , _lc_content :: !T.Text
  -- ^ 'Label.Label' content.
  } deriving (Show, Eq, Ord, Generic, Typeable)

-- | Run a 'LabelCmd' on the specified metric.
runModifyLabel :: EkgState -> String -> LabelCmd -> Process EkgState
runModifyLabel st (T.pack -> n) cmd  = do
  (st', m) <- case M.lookup n $ _ekg_metrics st of
    Just (EkgLabel l) -> return (st, Right l)
    Just m -> let wanted = Proxy :: Proxy Label.Label
              in return (st, Left $ unexpectedType n wanted m)
    Nothing -> do
      l <- liftIO $ getLabel n (_ekg_server st)
      let st' = st { _ekg_metrics = M.insert n (EkgLabel l) $ _ekg_metrics st }
      return (st', Right l)
  mreply <- case m of
    Left err -> say err >> return Nothing
    Right l -> liftIO $ case cmd of
      LabelRead -> do
        t <- Label.read l
        return . Just . LabelReadReply $! LabelContent n t
      LabelSet t -> Label.set l t >> return Nothing
  for_ mreply $ sendRC interface
  return st'

-- | Actions we can perform on 'Distribution.Distribution's.
data DistributionCmd = DistributionAdd !Double
                     -- ^ Corresponds to 'Distribution.add'.
                     | DistributionAddN !Double !Int64
                     -- ^ Corresponds to 'Distribution.addN'.
                     | DistributionRead
                     -- ^ Corresponds to 'Distribution.read'. RC
                     -- should listen for 'DistributionReadReply'.
  deriving (Show, Eq, Ord, Generic, Typeable)

-- | A reply sent to the RC for 'DistributionRead'.
data DistributionContent = DistributionContent
  { _dc_name :: !T.Text
  -- ^ 'Distribution.Distribution' metric name.
  , _dc_content :: !DistributionStats
  -- ^ 'Distribution.Distribution' content.
  } deriving (Show, Eq, Ord, Generic, Typeable)

-- | A locally-defined substitute for 'Distribution.Stats' providing
-- necessary instances.
data DistributionStats = DistributionStats
  { _ds_mean :: !Double
  -- ^ Corresponds to 'Distribution.mean'.
  , _ds_variance :: !Double
  -- ^ Corresponds to 'Distribution.variance'.
  , _ds_count :: !Int64
  -- ^ Corresponds to 'Distribution.count'.
  , _ds_sum :: !Double
  -- ^ Corresponds to 'Distribution.sum'.
  , _ds_min :: !Double
  -- ^ Corresponds to 'Distribution.min'.
  , _ds_max :: !Double
  -- ^ Corresponds to 'Distribution.max'.
  } deriving (Show, Eq, Ord, Typeable, Generic)

-- | Run a 'DistributionCmd' on the specified metric.
runModifyDistribution :: EkgState -> String -> DistributionCmd
                      -> Process EkgState
runModifyDistribution st (T.pack -> n) cmd  = do
  (st', m) <- case M.lookup n $ _ekg_metrics st of
    Just (EkgDistribution d) -> return (st, Right d)
    Just m -> let wanted = Proxy :: Proxy Distribution.Distribution
              in return (st, Left $ unexpectedType n wanted m)
    Nothing -> do
      d <- liftIO $ getDistribution n (_ekg_server st)
      let oldMap = _ekg_metrics st
          st' = st { _ekg_metrics = M.insert n (EkgDistribution d) oldMap }
      return (st', Right d)
  mreply <- case m of
    Left err -> say err >> return Nothing
    Right d -> liftIO $ case cmd of
      DistributionAdd v -> Distribution.add d v >> return Nothing
      DistributionAddN v i -> Distribution.addN d v i >> return Nothing
      DistributionRead -> do
        sts <- Distribution.read d
        let stats = DistributionStats
              { _ds_mean = Distribution.mean sts
              , _ds_variance = Distribution.variance sts
              , _ds_count = Distribution.count sts
              , _ds_sum = Distribution.sum sts
              , _ds_min = Distribution.min sts
              , _ds_max = Distribution.max sts }
        return . Just . DistributionReadReply $! DistributionContent n stats
  for_ mreply $ sendRC interface
  return st'

deriveSafeCopy 0 'base ''CounterCmd
deriveSafeCopy 0 'base ''CounterContent
deriveSafeCopy 0 'base ''DistributionCmd
deriveSafeCopy 0 'base ''DistributionContent
deriveSafeCopy 0 'base ''DistributionStats
deriveSafeCopy 0 'base ''GaugeCmd
deriveSafeCopy 0 'base ''GaugeContent
deriveSafeCopy 0 'base ''LabelCmd
deriveSafeCopy 0 'base ''LabelContent
deriveSafeCopy 0 'base ''MetricReadReply
deriveSafeCopy 0 'base ''ModifyMetric
