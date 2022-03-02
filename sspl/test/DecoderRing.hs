-- |
-- Copyright : (C) 2014 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Test decoding.

import SSPL.Bindings

import Data.Aeson (Value, decode)
import qualified Data.ByteString.Lazy as LB

import System.Environment (getArgs)

main :: IO ()
main = do
  bs <- LB.getContents
  case decode bs :: Maybe SensorResponse of
    Just mr -> print mr
    Nothing -> putStrLn "Unable to decode as MonitorResponse."
  case decode bs :: Maybe Value of
    Just v -> print v
    Nothing -> putStrLn "Unable to decode as JSON Value."
  LB.putStr bs
