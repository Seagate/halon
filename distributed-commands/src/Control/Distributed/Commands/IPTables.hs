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
import Data.List (findIndex)
import System.Exit


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
      inputRules <- listIPTablesAsUser user h "INPUT"
      let p ["DROP", "all", "--", '!' : _, "0.0.0.0/0"] = True
          p _ = False
      case findIndex p inputRules of
        Just i ->
          systemThereAsUser user [h] $ "iptables -D INPUT " ++ show (i + 1)
        _ -> return ()
      outputRules <- listIPTablesAsUser user h "OUTPUT"
      let q ["DROP", "all", "--", "0.0.0.0/0", '!' : _] = True
          q _ = False
      case findIndex q outputRules of
        Just i ->
          systemThereAsUser user [h] $ "iptables -D OUTPUT " ++ show (i + 1)
        _ -> return ()

-- | @listIPTablesAsUser user h chain@ yields the rules of @chain@ in @h@ using
-- the given @user@.
listIPTablesAsUser :: String -> HostName -> String -> IO [[String]]
listIPTablesAsUser user h chain = do
    rLine <- C.systemThereAsUser user h $ "iptables -n -L " ++ chain
    (output, ExitSuccess) <- C.waitForCommand rLine
    return $ map words $ drop 2 output

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
    forM_ hostPairs $ \(from, to) -> do
      rules <- listIPTablesAsUser user to "INPUT"
      let p ["DROP", "all", "--", from', "0.0.0.0/0"] = from == from'
          p _ = False
      case findIndex p rules of
        Just i ->
          systemThereAsUser user [to] $ "iptables -D INPUT " ++ show (i + 1)
        _ -> return ()
