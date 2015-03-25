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

import Control.Distributed.Commands.Management
import qualified Control.Distributed.Commands as C

import Control.Monad


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
      systemThereAsUser user [h] $ dropTrafficExceptFrom here

-- | Recovers communications of the given hosts undoing the effect of
-- isolateHostsAsUser.
rejoinHostsAsUser :: String -> [HostName] -> IO ()
rejoinHostsAsUser user =
    mapM_ $ \h -> do
      testIPTablesAsUser user h "INPUT" $ \case
        ["DROP", "all", "--", _, "anywhere"] -> do
           systemThereAsUser user [h] "iptables -D INPUT 1"
        _ -> return ()
      testIPTablesAsUser user h "OUTPUT" $ \case
        ["DROP", "all", "--", "anywhere", _] -> do
           systemThereAsUser user [h] "iptables -D OUTPUT 1"
        _ -> return ()

-- | @testIPTablesAsUser user h chain f@ feeds to @f@ the first rule of @chain@
-- in @h@ using the given @user@.
testIPTablesAsUser :: String -> HostName -> String -> ([String] -> IO a) -> IO a
testIPTablesAsUser user h chain f = do
    rLine <- C.systemThereAsUser user h $ "iptables -L " ++ chain
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
      systemThereAsUser user [to] $ dropTrafficFrom [from]

-- | Recover communications from a host to another, undoing the effect of
-- cutLinks.
reenableLinksAsUser :: String -> [(HostName, HostName)] -> IO ()
reenableLinksAsUser user hostPairs =
    forM_ hostPairs $ \(from, to) ->
      testIPTablesAsUser user to "INPUT" $ \case
        ["DROP", "all", "--", from', "anywhere"] | from == from' -> do
           systemThereAsUser user [to] "iptables -D INPUT 1"
        _ -> return ()
