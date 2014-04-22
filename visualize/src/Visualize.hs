module Main where

import Tree
import Draw

import qualified Network.Socket as N
import qualified Network.BSD as N
import Control.Monad
import Control.Concurrent
import Control.Concurrent.Chan
import Data.Hashable


pull sock chan = do
  (msg, _, addr) <- N.recvFrom sock 1024
  let [level, leader, member] = words msg
  writeChan chan $ LeaderElected (read level) (hash leader) (hash member)
  pull sock chan

main = do
  sock <- N.socket N.AF_INET N.Datagram N.defaultProtocol
  addr <- liftM N.hostAddress $ N.getHostByName "localhost"
  N.bindSocket sock (N.SockAddrInet 9090 addr)
  incoming <- newChan
  forkIO $ pull sock incoming
  doAnimation incoming

