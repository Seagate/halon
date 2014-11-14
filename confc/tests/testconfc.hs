--
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This program prints in stdout the contents of the configuration in confd.
-- Call as: ./testconfc local_rpc_address confd_rpc_address

import Mero.ConfC

import Network.Transport.RPC ( RPCTransport(..), rpcAddress, withTransport
                             , defaultRPCParameters
                             )
import Network.Transport.RPC.RPCLite ( getRPCMachine_se )

import Data.Bits
import Data.Char ( toUpper )
import Data.List ( intersperse )
import Numeric ( showHex )
import System.Environment ( getArgs )

main :: IO ()
main =
  getArgs >>= \[ localAddress , confdAddress ] ->
  withTransport "s1" (rpcAddress localAddress) defaultRPCParameters
  $ \tr -> getRPCMachine_se (serverEndPoint tr)
  >>= \rpcMachine -> withConfC $ do
    -- See $MERO_ROOT/conf/ut/confc.c for examples of how fid objects
    -- are created.
    --
    -- root_fid is created to match the identifier used in
    -- $MERO_ROOT/m0t1fs/linux_kernel/st/st
    let root_fid = Fid (fromIntegral (fromEnum 'p') `shiftL` (64 - 8) .|. 17) 0
    withClose (getRoot rpcMachine (rpcAddress confdAddress) root_fid)
              $ printCObj 0

printCObj :: Int -> CObj -> IO ()
printCObj i co = do
    putStr $ (showFid . co_id $ co) ++ ": "
    printCOData i $ co_union co

showFid :: Fid -> String
showFid (Fid c k) = "m0_fid(0x" ++ map toUpper (showHex c "")
                                ++ "," ++ show k ++ ")"

printCOData :: Int -> CObjUnion -> IO ()
printCOData i cou =
  case cou of
    CP p  -> printProfile i p
    CF fs -> printFilesystem i fs
    CD d  -> printDir i d
    CS s  -> printService i s
    CN n  -> printNode i n
    NI n  -> printNic i n
    SD s  -> printSdev i s
    COUnknown t -> putStrLn $ "unknown: "++show t

printProfile :: Int -> Profile -> IO ()
printProfile i p = do
   putStrLn "m0_conf_profile {}"
   withClose (cp_filesystem p) $ printChild (i+2) "filesystem"

printChild :: Int -> String -> CObj -> IO ()
printChild i name co = do
    putStr $ replicate i ' ' ++ name ++ ": "
    printCObj i co

printFilesystem :: Int -> Filesystem -> IO ()
printFilesystem i fs = do
    putStr "m0_conf_filesystem { "
    putStr $ "rootfid = "
              ++ showFid (cf_rootfid fs)
              ++ ", params = "
    if null $ cf_params fs then putStr  "[]"
      else mapM_ putStr $ intersperse " " $ "[" : cf_params fs ++ ["]"]
    putStrLn " }"
    withClose (cf_services fs) $ printChild (i+2) "services"

printDir :: Int -> Dir -> IO ()
printDir i d = do
    putStrLn "m0_conf_dir {}"
    withClose (cd_iterator d) go
  where
    go :: Iterator -> IO ()
    go it = ci_next it >>= maybe (return ())
                                 (\co -> do putStr $ replicate (i+2) ' '
                                            printCObj (i+2) co
                                            go it
                                 )

printService :: Int -> Service -> IO ()
printService i s = do
    putStr $ "m0_conf_service { type = M0_" ++ show (cs_type s)
    putStr ", endpoints = "
    if null $ cs_endpoints s then putStr  "[]"
      else mapM_ putStr $ intersperse " " $ "[" : cs_endpoints s ++ ["]"]
    putStrLn " }"
    withClose (cs_node s) $ printChild (i+2) "node"

printNode :: Int -> Node -> IO ()
printNode i n = do
    putStr $ "m0_conf_node { memsize = " ++ show (cn_memsize n)
    putStr $ ", nr_cpu = " ++ show (cn_nr_cpu n)
    putStr $ ", last_state = " ++ show (cn_last_state n)
    putStr $ ", flags = " ++ show (cn_flags n)
    putStr $ ", pool_id = " ++ show (cn_pool_id n)
    putStrLn " }"
    withClose (cn_nics n) $ printChild (i+2) "nics"
    withClose (cn_sdevs n) $ printChild (i+2) "sdevs"

printNic :: Int -> Nic -> IO ()
printNic _ n = do
    putStr $ "m0_conf_nic { iface = " ++ show (ni_iface n)
    putStr $ ", mtu = " ++ show (ni_mtu n)
    putStr $ ", speed = " ++ show (ni_speed n)
    putStr $ ", filename = " ++ ni_filename n
    putStr $ ", last_state = " ++ show (ni_last_state n)
    putStrLn " }"

printSdev :: Int -> Sdev -> IO ()
printSdev _ s = do
    putStr $ "m0_conf_sdev { iface = " ++ show (sd_iface s)
    putStr $ ", media = " ++ show (sd_media s)
    putStr $ ", size = " ++ show (sd_size s)
    putStr $ ", last_state = " ++ show (sd_last_state s)
    putStr $ ", flags = " ++ show (sd_flags s)
    putStr $ ", filename = " ++ sd_filename s
    putStrLn " }"
