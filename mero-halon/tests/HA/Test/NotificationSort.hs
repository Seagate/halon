-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Test the NVec notification sorting mechanism.
module HA.Test.NotificationSort (tests) where

import Data.Proxy
import GHC.Word (Word64)
import HA.Resources.Mero as M0
import HA.Resources.Mero.Note (ConfObjectState(..))
import HA.Services.Mero.RC.Actions (orderSet)
import Mero.ConfC (Fid)
import Mero.Notification (Set(..))
import Mero.Notification.HAState (Note(..))
import Test.Framework
import Test.Tasty.HUnit (assertEqual)

tests :: [TestTree]
tests = [ testSuccess "sortsInteresting" sortsInteresting
        , testSuccess "sortsUninteresting" sortsUninteresting
        ]

mkN :: [Fid] -> Set
mkN fs = Set (map (\fid' -> Note fid' M0_NC_ONLINE) fs) Nothing

-- | Sorts interesting things in correct order and puts un-interesting
-- thing in the back
sortsInteresting :: IO ()
sortsInteresting = do
  assertEqual "Sorts interesting" (orderSet ordering $ mkN startSet) (mkN stopSet)
  where
    startSet :: [Fid]
    startSet = [ M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 2)
               , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 3)
               , M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 1)
               , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 1)
               , M0.fid $ M0.RackV (M0.fidInit (Proxy :: Proxy M0.RackV) 1 1)
               , M0.fid $ M0.Disk (M0.fidInit (Proxy :: Proxy M0.Disk) 1 1)
               , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 2)
               ]

    stopSet :: [Fid]
    stopSet = [ M0.fid $ M0.Disk (M0.fidInit (Proxy :: Proxy M0.Disk) 1 1)
              , M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 1)
              , M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 2)
              , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 1)
              , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 2)
              , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 3)
              , M0.fid $ M0.RackV (M0.fidInit (Proxy :: Proxy M0.RackV) 1 1)
              ]

    ordering :: [Word64]
    ordering = [ M0.confToFidType (Proxy :: Proxy M0.Disk)
               , M0.confToFidType (Proxy :: Proxy M0.Enclosure)
               , M0.confToFidType (Proxy :: Proxy M0.Controller)
               ]

-- | Sorts uninteresting things
sortsUninteresting :: IO ()
sortsUninteresting = do
  assertEqual "Sorts uninteresting" (orderSet [] $ mkN startSet) (mkN stopSet)
  where
    startSet :: [Fid]
    startSet = [ M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 2)
               , M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 1)
               , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 3)
               , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 1)
               , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 2)
               ]

    stopSet :: [Fid]
    stopSet = [ M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 1)
              , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 2)
              , M0.fid $ M0.Controller (M0.fidInit (Proxy :: Proxy M0.Controller) 1 3)
              , M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 1)
              , M0.fid $ M0.Enclosure (M0.fidInit (Proxy :: Proxy M0.Enclosure) 1 2)
              ]
