-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This module provides scp and ssh conveniently wrapped to use them
-- in scripts.
--

{-# LANGUAGE LambdaCase #-}
module Control.Distributed.Commands.IPTables
    ( isolateHostsAsUser
    , rejoinHostsAsUser
    , cutLinksAsUser
    , reenableLinksAsUser
    )
  where

import Control.Distributed.Commands

import Control.Monad
import Network (HostName)


dropTrafficExceptFrom :: HostName -> String
dropTrafficExceptFrom here =
    "iptables -I INPUT ! -s " ++ here ++ " -j DROP; " ++
    "iptables -I OUTPUT ! -d " ++ here ++ " -j DROP"

dropTrafficFrom :: [HostName] -> String
dropTrafficFrom = concatMap $ \here ->
    "iptables -I INPUT -s " ++ here ++ " -j DROP"

-- | @isolateHostsAsUser user here hosts@
--
-- Stops communication of the given @hosts@ except from @here@ which can
-- connect to the hosts as @user@ to reenable communications.
isolateHostsAsUser :: String -> HostName -> [HostName] -> IO ()
isolateHostsAsUser user here hosts = do
    -- undo first the effect of any previos call to @isolateHostsAsUser@.
    rejoinHostsAsUser user hosts
    forM_ hosts $ \h -> do
      void $ systemThereAsUser user h $ dropTrafficExceptFrom here
      waitForChanges user h "INPUT" $ \case
        ["DROP", "all", "--", _, "anywhere"] -> True
        _ -> False
      waitForChanges user h "OUTPUT" $ \case
        ["DROP", "all", "--", "anywhere", _] -> True
        _ -> False

-- | Recovers communications of the given hosts undoing the effect of
-- isolateHostsAsUser.
rejoinHostsAsUser :: String -> [HostName] -> IO ()
rejoinHostsAsUser user =
    mapM_ $ \h -> do
      testIPTablesAsUser user h "INPUT" $ \case
        ["DROP", "all", "--", _, "anywhere"] -> do
           void $ systemThereAsUser user h "iptables -D INPUT 1"
           waitForChanges user h "INPUT" $ \case
             ["DROP", "all", "--", _, "anywhere"] -> False
             _ -> True
        _ -> return ()
      testIPTablesAsUser user h "OUTPUT" $ \case
        ["DROP", "all", "--", "anywhere", _] -> do
           void $ systemThereAsUser user h "iptables -D OUTPUT 1"
           waitForChanges user h "OUTPUT" $ \case
             ["DROP", "all", "--", "anywhere", _] -> False
             _ -> True
        _ -> return ()

-- | @testIPTablesAsUser user h chain f@ feeds to @f@ the first rule of @chain@
-- in @h@ using the given @user@.
testIPTablesAsUser :: String -> HostName -> String -> ([String] -> IO a) -> IO a
testIPTablesAsUser user h chain f = do
    rLine <- systemThereAsUser user h $ "iptables -L " ++ chain
    _ <- rLine
    _ <- rLine
    rLine >>= f . either (const []) words

-- | Disables communications from a host to another.
--
-- If you want to cut communications in both ways, both @(host1, host2)@ and
-- @(host2, host1)@ pairs need to be provided in the input list.
cutLinksAsUser :: String -> [(HostName, HostName)] -> IO ()
cutLinksAsUser user hostPairs = do
    -- Undo first the effect of any previous call to @cutLinksAsUser@.
    reenableLinksAsUser user hostPairs
    forM_ hostPairs $ \(from, to) -> do
      void $ systemThereAsUser user to $ dropTrafficFrom [from]
      waitForChanges user to "INPUT" $ \case
        ["DROP", "all", "--", _, "anywhere"] -> True
        _ -> False

-- | @waitForChanges user h chain p@ feeds to @p@ the first rule of @chain@
-- in @h@ using the given @user@ until @p@ returns @True@.
waitForChanges :: String -> HostName -> String -> ([String] -> Bool) -> IO ()
waitForChanges user h chain p = testIPTablesAsUser user h chain $ \rule ->
    unless (p rule) $ waitForChanges user h chain p

-- | Recover communications from a host to another, undoing the effect of
-- cutLinks.
reenableLinksAsUser :: String -> [(HostName, HostName)] -> IO ()
reenableLinksAsUser user hostPairs =
    forM_ hostPairs $ \(from, to) ->
      testIPTablesAsUser user to "INPUT" $ \case
        ["DROP", "all", "--", from', "anywhere"] | from == from' -> do
           void $ systemThereAsUser user to "iptables -D INPUT 1"
           waitForChanges user to "INPUT" $ \case
             ["DROP", "all", "--", from'', "anywhere"] | from == from'' -> False
             _ -> True
        _ -> return ()
