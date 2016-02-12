-- |
-- Module: Mero.Environment
-- Copyright: (C) 2015 Seagate Technology Limited.
{-# LANGUAGE ForeignFunctionInterface #-}
module Mero.Environment 
  ( initializeFOPs
  , deinitializeFOPs
  ) where

initializeFOPs :: IO ()
initializeFOPs = do
  c_m0_sns_cm_repair_trigger_fop_init
  c_m0_sns_cm_rebalance_trigger_fop_init

deinitializeFOPs :: IO ()
deinitializeFOPs = do
  c_m0_sns_cm_rebalance_trigger_fop_fini
  c_m0_sns_cm_repair_trigger_fop_fini

foreign import ccall "cm/cm.h m0_sns_cm_repair_trigger_fop_init"
  c_m0_sns_cm_repair_trigger_fop_init :: IO ()

foreign import ccall "cm/cm.h m0_sns_cm_rebalance_trigger_fop_init"
  c_m0_sns_cm_rebalance_trigger_fop_init :: IO ()

foreign import ccall "cm/cm.h m0_sns_cm_repair_trigger_fop_fini"
  c_m0_sns_cm_repair_trigger_fop_fini :: IO ()

foreign import ccall "cm/cm.h m0_sns_cm_rebalance_trigger_fop_fini"
  c_m0_sns_cm_rebalance_trigger_fop_fini :: IO ()
