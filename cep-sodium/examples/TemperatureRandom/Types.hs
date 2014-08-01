{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Types where

import Data.Binary (Binary)
import Data.Typeable (Typeable)

newtype Temperature = Temperature {
  unTemp :: Double
  } deriving (Typeable, Binary, Show, Eq, Ord, Num, Real, Fractional)

newtype AverageTemperature = AverageTemperature {
  unAvg :: Temperature
  } deriving (Typeable, Binary, Eq, Ord, Num, Real, Fractional)

instance Show AverageTemperature where
  show (AverageTemperature (Temperature t)) = show t
