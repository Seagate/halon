{-# LANGUAGE CApiFFI                  #-}
{-# LANGUAGE DeriveDataTypeable       #-}
{-# LANGUAGE DeriveGeneric            #-}
{-# LANGUAGE EmptyDataDecls           #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE MultiWayIf               #-}
{-# LANGUAGE TemplateHaskell          #-}
{-# LANGUAGE TupleSections            #-}

-- |
-- Copyright : (C) 2015-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- Bindings to the confc client library. confc allows programs to
-- get data from the Mero confd service.
--
-- This file provides bindings to the various object types defined in
-- @conf/obj.h@
--
module Mero.Conf.Obj
  ( ServiceType(..)
  , confPVerLvlDrives
  ) where

#include "conf/obj.h"  /* M0_CONF_PVER_LVL_DISKS */

import Data.Aeson (FromJSON, ToJSON)
import Data.Binary (Binary)
import Data.Data (Data)
import Data.Hashable (Hashable)
import Data.SafeCopy (deriveSafeCopy, base)
import GHC.Generics (Generic)

confPVerLvlDrives :: Int
confPVerLvlDrives = #{const M0_CONF_PVER_LVL_DRIVES}

data {-# CTYPE "conf/schema.h" "struct m0_conf_service_type" #-} ServiceType
    = CST_MDS     -- ^ Meta-data service
    | CST_IOS     -- ^ IO service
    | CST_CONFD   -- ^ Confd service
    | CST_RMS     -- ^ Resource management
    | CST_STATS   -- ^ Stats service
    | CST_HA      -- ^ HA service
    | CST_SSS     -- ^ Start/stop service
    | CST_SNS_REP -- ^ SNS repair
    | CST_SNS_REB -- ^ SNS rebalance
    | CST_ADDB2   -- ^ ADDB service
    | CST_CAS     -- ^ Catalogue service
    | CST_DIX_REP -- ^ Dix repair
    | CST_DIX_REB -- ^ Dix rebalance
    | CST_DS1     -- ^ Dummy service 1
    | CST_DS2     -- ^ Dummy service 2
    | CST_FIS     -- ^ Fault injection service
    | CST_FDMI    -- ^ FDMI service
    | CST_BE      -- ^ BE service
    | CST_M0T1FS  -- ^ m0t1fs service
    | CST_CLOVIS  -- ^ Clovis service
    | CST_ISCS    -- ^ ISC service
    | CST_UNKNOWN Int
  deriving (Data, Eq, Generic, Ord, Read, Show)

instance Binary ServiceType
instance Hashable ServiceType
instance FromJSON ServiceType
instance ToJSON ServiceType

instance Enum ServiceType where
  toEnum #{const M0_CST_MDS}     = CST_MDS
  toEnum #{const M0_CST_IOS}     = CST_IOS
  toEnum #{const M0_CST_CONFD}   = CST_CONFD
  toEnum #{const M0_CST_RMS}     = CST_RMS
  toEnum #{const M0_CST_STATS}   = CST_STATS
  toEnum #{const M0_CST_HA}      = CST_HA
  toEnum #{const M0_CST_SSS}     = CST_SSS
  toEnum #{const M0_CST_SNS_REP} = CST_SNS_REP
  toEnum #{const M0_CST_SNS_REB} = CST_SNS_REB
  toEnum #{const M0_CST_ADDB2}   = CST_ADDB2
  toEnum #{const M0_CST_CAS}     = CST_CAS
  toEnum #{const M0_CST_DIX_REP} = CST_DIX_REP
  toEnum #{const M0_CST_DIX_REB} = CST_DIX_REB
  toEnum #{const M0_CST_DS1}     = CST_DS1
  toEnum #{const M0_CST_DS2}     = CST_DS2
  toEnum #{const M0_CST_FIS}     = CST_FIS
  toEnum #{const M0_CST_FDMI}    = CST_FDMI
  toEnum #{const M0_CST_BE}      = CST_BE
  toEnum #{const M0_CST_M0T1FS}  = CST_M0T1FS
  toEnum #{const M0_CST_CLOVIS}  = CST_CLOVIS
  toEnum #{const M0_CST_ISCS}    = CST_ISCS
  toEnum i                       = CST_UNKNOWN i

  fromEnum CST_MDS         = #{const M0_CST_MDS}
  fromEnum CST_IOS         = #{const M0_CST_IOS}
  fromEnum CST_CONFD       = #{const M0_CST_CONFD}
  fromEnum CST_RMS         = #{const M0_CST_RMS}
  fromEnum CST_STATS       = #{const M0_CST_STATS}
  fromEnum CST_HA          = #{const M0_CST_HA}
  fromEnum CST_SSS         = #{const M0_CST_SSS}
  fromEnum CST_SNS_REP     = #{const M0_CST_SNS_REP}
  fromEnum CST_SNS_REB     = #{const M0_CST_SNS_REB}
  fromEnum CST_ADDB2       = #{const M0_CST_ADDB2}
  fromEnum CST_CAS         = #{const M0_CST_CAS}
  fromEnum CST_DIX_REP     = #{const M0_CST_DIX_REP}
  fromEnum CST_DIX_REB     = #{const M0_CST_DIX_REB}
  fromEnum CST_DS1         = #{const M0_CST_DS1}
  fromEnum CST_DS2         = #{const M0_CST_DS2}
  fromEnum CST_FIS         = #{const M0_CST_FIS}
  fromEnum CST_FDMI        = #{const M0_CST_FDMI}
  fromEnum CST_BE          = #{const M0_CST_BE}
  fromEnum CST_M0T1FS      = #{const M0_CST_M0T1FS}
  fromEnum CST_CLOVIS      = #{const M0_CST_CLOVIS}
  fromEnum CST_ISCS        = #{const M0_CST_ISCS}
  fromEnum (CST_UNKNOWN i) = i

deriveSafeCopy 0 'base ''ServiceType
