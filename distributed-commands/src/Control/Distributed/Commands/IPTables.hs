-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Primitives to break communications between hosts.

{-# LANGUAGE LambdaCase #-}
module Control.Distributed.Commands.IPTables
    ( isolateHostsAsUser
    , rejoinHostsAsUser
    , cutLinksAsUser
    , reenableLinksAsUser
    )
  where

import Control.Distributed.Commands.Management


-- | @isolateHostsAsUser user isolated universe@
--
-- Stops communication of the given @isolated@ hosts.
--
-- @user@ must have enough privileges to use iptables.
--
-- Universe is the list of all hosts which cannot talk to @isolated@ hosts.
isolateHostsAsUser :: String -> [HostName] -> [HostName] -> IO ()
isolateHostsAsUser user isolated universe = do
    cutLinksAsUser user isolated universe
    cutLinksAsUser user universe isolated

-- | Recovers communications of the given hosts undoing the effect of
-- 'isolateHostsAsUser'.
rejoinHostsAsUser :: String -> [HostName] -> [HostName] -> IO ()
rejoinHostsAsUser user isolated universe = do
    reenableLinksAsUser user isolated universe
    reenableLinksAsUser user universe isolated

-- | @cutLinksAsUser user from to@ disables communications from hosts in @from@
-- to hosts in @to@.
--
-- If you want to cut communications in both ways, two calls are necessary:
--
-- > cutLinksAsUser user from to
-- > cutLinksAsUser user to   from
--
cutLinksAsUser :: String -> [HostName] -> [HostName] -> IO ()
cutLinksAsUser user from to = do
    systemThereAsUser user to $
      "for h in " ++ unwords from ++
        "; do iptables -I INPUT -s $h -j DROP; done"

-- | Recover communications from some hosts to others, undoing the effect of
-- 'cutLinksAsUser'.
reenableLinksAsUser :: String -> [HostName] -> [HostName] -> IO ()
reenableLinksAsUser user from to =
    systemThereAsUser user to $
      "for h in " ++ unwords from ++
        "; do iptables -D INPUT -s $h -p all -j DROP; true; done"
