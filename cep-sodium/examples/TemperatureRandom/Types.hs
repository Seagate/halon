{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE TemplateHaskell            #-}

module Types where

import Data.Binary (Binary)
import Data.Typeable (Typeable)

import Control.Distributed.Process.Closure (mkStatic, remotable)

import Network.CEP.Types

newtype Temperature = Temperature
  { unTemp :: Double
  } deriving (Typeable, Binary, Show, Eq, Ord, Num, Real, Fractional)

newtype AverageTemperature = AverageTemperature
  { unAvg :: Temperature
  } deriving (Typeable, Binary, Eq, Ord, Num, Real, Fractional)

instance Show AverageTemperature where
  show (AverageTemperature (Temperature t)) = show t


sinstTemp :: Instance (Statically Emittable) Temperature
sinstAvg  :: Instance (Statically Emittable) AverageTemperature
(sinstTemp, sinstAvg) = (Instance, Instance)
remotable [ 'sinstTemp, 'sinstAvg ]

instance Emittable Temperature
instance Emittable AverageTemperature

instance Statically Emittable Temperature where
  staticInstance = $(mkStatic 'sinstTemp)
instance Statically Emittable AverageTemperature where
  staticInstance = $(mkStatic 'sinstAvg)
