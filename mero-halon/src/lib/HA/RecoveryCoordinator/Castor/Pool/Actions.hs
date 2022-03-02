{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeOperators       #-}
-- |
-- Copyright : (C) 2017 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
module HA.RecoveryCoordinator.Castor.Pool.Actions
  ( getNonMD
  , getPools
  , getSDevs
  , getSDevsWithState
  ) where

import qualified Data.HashSet as S
import           Data.List (partition)
import           Data.Maybe (listToMaybe)

import qualified HA.ResourceGraph as G
import qualified HA.Resources.Mero as M0
import qualified HA.Resources.Mero.Note as M0

-- | Find all 'M0.Pool's in the RG that aren't metadata pools. See
-- also 'getPools'.
--
-- XXX-MULTIPOOLS: DELETEME
getNonMD :: G.Graph -> [M0.Pool]
getNonMD rg =
  [ pool
  | let root = M0.getM0Root rg
  , pool <- G.connectedTo root M0.IsParentOf rg
  , M0.fid pool /= M0.rt_mdpool root
  ]

-- | Returns SNS pools and the DIX pool.
getPools :: G.Graph -> ([M0.Pool], Maybe M0.Pool)
getPools rg = let (dix, sns) = partition isDixPool (getNonMD rg)
              in (sns, listToMaybe dix)
  where
    root = M0.getM0Root rg

    pvers :: M0.Pool -> [M0.PVer]
    pvers pool = G.connectedTo pool M0.IsParentOf rg

    isDixPool :: M0.Pool -> Bool
    isDixPool = elem (M0.rt_imeta_pver root) . map M0.v_fid . pvers

-- | Get all 'M0.SDev's that belong to the given 'M0.Pool'.
--
-- Works on the assumption that every disk belonging to the pool
-- appears in at least one pool version belonging to the pool. In
-- other words,
--
-- "If pool doesn't contain a disk in some pool version => disk
-- doesn't belong to the pool." See discussion at
-- https://seagate.slack.com/archives/mero-halon/p1457632533003295 for
-- details.
getSDevs :: M0.Pool -> G.Graph -> [M0.SDev]
getSDevs pool rg =
    S.toList . S.fromList $
        [ sd
        | pv <- G.connectedTo pool M0.IsParentOf rg :: [M0.PVer]
        , sv <- G.connectedTo pv M0.IsParentOf rg :: [M0.SiteV]
        , rv <- G.connectedTo sv M0.IsParentOf rg :: [M0.RackV]
        , ev <- G.connectedTo rv M0.IsParentOf rg :: [M0.EnclosureV]
        , ct <- G.connectedTo ev M0.IsParentOf rg :: [M0.ControllerV]
        , dv <- G.connectedTo ct M0.IsParentOf rg :: [M0.DiskV]
        , Just d <- [G.connectedFrom M0.IsRealOf dv rg :: Maybe M0.Disk]
        , Just sd <- [G.connectedFrom M0.IsOnHardware d rg :: Maybe M0.SDev]
        ]

-- | Get all 'M0.SDev's in the given 'M0.Pool' with the given
-- 'M0.ConfObjState'.
getSDevsWithState :: M0.Pool -> M0.ConfObjectState -> G.Graph -> [M0.SDev]
getSDevsWithState pool st rg =
  [ sdev
  | sdev <- getSDevs pool rg
  , st == M0.getConfObjState sdev rg
  ]
