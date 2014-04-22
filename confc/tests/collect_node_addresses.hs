--
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--

-- This program prints in stdout the addresses of nodes obtained from
-- service endpoints.
-- Call as: ./collect_node_addresses local_rpc_address confd_rpc_address

import Mero.ConfC

import Network.Transport.RPC ( RPCTransport(..), rpcAddress, withTransport
                             , defaultRPCParameters
                             )
import Network.Transport.RPC.RPCLite ( getRPCMachine_se )

import Data.List ( nub )
import System.Environment ( getArgs )


main :: IO ()
main =
  getArgs >>= \[ localAddress , confdAddress ] ->
  withTransport "s1" (rpcAddress localAddress) defaultRPCParameters
  $ \tr -> getRPCMachine_se (serverEndPoint tr)
  >>= \rpcMachine -> withConfC
  $ withClose (getRoot rpcMachine (rpcAddress confdAddress) "prof-1")
              collectNodeAddresses
  >>= mapM_ putStrLn

-- | Scans the service endpoints from a configuration root to extract the node
-- addresses from them.
--
collectNodeAddresses :: CObj -> IO [String]
collectNodeAddresses CObj { co_union = CP p} =
    withClose (cp_filesystem p) $ \cofs ->
    case co_union cofs of
      CF fs -> withClose (cf_services fs) $ \cod ->
        case co_union cod of
          CD d -> do eps <- withClose (cd_iterator d) $ getEndpoints []
                     return $ nub $ concat $ map (take 1 . map pruneIpNet) eps
          _ -> return []
      _ -> return []
  where
    pruneIpNet = takeWhile (':'/=) . drop 1 . dropWhile (':'/=)

    getEndpoints :: [[String]] -> Iterator -> IO [[String]]
    getEndpoints acc i =  ci_next i >>= maybe (return acc) (\cose ->
             case co_union cose of
               CS s -> getEndpoints (cs_endpoints s : acc) i
               _ -> getEndpoints acc i
           )
collectNodeAddresses _ = return []

