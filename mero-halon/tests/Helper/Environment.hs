-- | 
-- Copyright : (C) 2015 Seagate Technology Limited.
-- 
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ForeignFunctionInterface #-}
{-# LANGUAGE CPP #-}
module Helper.Environment
  ( withSudo
  , withMeroRoot
  , withMeroEnvironment
#ifdef USE_MERO
  , withHASession
  , withEndpoint
#endif
  , confdEndpoint
  , confd2Endpoint
  , getConfdEndpoint
  , getConfd2Endpoint
  , getHalonEndpoint
  , getLnetNid
  , systemHostname
  ) where

#ifdef USE_MERO
import Network.RPC.RPCLite
import Control.Exception (bracket)
import Foreign.C
import Foreign.Ptr
import System.IO
#endif

import Control.Exception (bracket_, onException, IOException, try)
import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Maybe (catMaybes)
import Network.BSD
import System.Environment
    ( lookupEnv
    , setEnv
    , getExecutablePath)
import System.Exit (exitSuccess)
import System.IO.Unsafe
import System.Posix.User (getEffectiveUserID)
import System.Process (readProcess, callProcess, callCommand)
import GHC.Environment (getFullArgs)

withSudo :: [String] -> IO () -> IO ()
withSudo envvars tests = do
  uid <- getEffectiveUserID
  when (uid /= 0) $ do
    prog <- getExecutablePath
    args <- getFullArgs
    env  <- catMaybes <$> mapM (\e -> fmap (\v -> e ++ "=" ++ v) <$> lookupEnv e)
                               envvars
    (callProcess "sudo" $ env ++ prog : args)
      `onException` (putStrLn "Error when running tests.")
    exitSuccess
  tests

withMeroRoot :: (String -> IO a) -> IO a
withMeroRoot f = lookupEnv "MERO_ROOT" >>= \case
  Nothing -> error "Please specify MERO_ROOT environment variable in order to run test."
  Just x  -> f x

getLnetNid :: IO String
getLnetNid = head . lines <$> readProcess "lctl" ["list_nids"] ""

-- | Endpoints environment names.
confdEndpoint, confd2Endpoint, halonEndpoint :: String
confdEndpoint = "SERVER1_ENDPOINT"
confd2Endpoint = "SERVER2_ENDPOINT"
halonEndpoint = "HALON_ENDPOINT" 

-- | Get confd endpoint address.
getConfdEndpoint :: IO String
getConfdEndpoint = lookupEnv confdEndpoint >>= \case
  Nothing -> (++) <$> getLnetNid <*> pure ":12345:34:101"
  Just nid -> return nid

-- | Get confd endpoint address.
getConfd2Endpoint :: IO String
getConfd2Endpoint = lookupEnv confdEndpoint >>= \case
  Nothing -> (++) <$> getLnetNid <*> pure ":12345:44:102"
  Just nid -> return nid

-- | Get halon endpoint address.
getHalonEndpoint :: IO String
getHalonEndpoint = lookupEnv halonEndpoint >>= \case
  Nothing -> (++) <$> getLnetNid <*> pure ":12345:35:401"
  Just nid -> return nid

withMeroEnvironment :: IO (Maybe (IO ())) -> IO () -> IO ()
withMeroEnvironment router wrapper = withMeroRoot $ \meroRoot ->
  withSudo ["LD_LIBRARY_PATH", "MERO_ROOT", "TASTY_PATTERN", "TEST_LISTEN"] $ do
    mtest <- router
    case mtest of 
      Just test -> test
      Nothing -> bracket_
        (do setEnv "SANDBOX_DIR" "/var/mero/sandbox.mero-halon-st"
            callCommand $ meroRoot ++ "/conf/st sstart"
            )

        (do threadDelay $ 2*1000000
            _ <- tryIO $ callCommand $ meroRoot ++ "/conf/st sstop"
            threadDelay $ 2*1000000
            -- XXX: workaround for a bug in a mero test suite.
            _ <- tryIO $ callCommand $ "killall -9 lt-m0d"
            threadDelay $ 2*1000000
            _ <- tryIO $ callCommand $ meroRoot ++ "/conf/st rmmod"
            return ()) 
        (do nid <- getLnetNid
            setEnv confdEndpoint  $ nid ++ ":12345:34:1001"
            setEnv confd2Endpoint $ nid ++ ":12345:34:1002"
            setEnv halonEndpoint  $ nid ++ ":12345:35:401"
            wrapper)

tryIO :: IO a -> IO (Either IOException a)
tryIO = try

#ifdef USE_MERO
foreign import ccall "<ha/note.h> m0_ha_state_init"
  c_ha_state_init :: Ptr SessionV -> IO CInt

foreign import ccall "<ha/note.h> m0_ha_state_fini"
  c_ha_state_fini :: IO ()

withHASession :: ServerEndpoint -> RPCAddress -> IO a -> IO a
withHASession sep addr f =
   bracket (connect_se sep addr 2)
           (`disconnect` 2)
     $ \conn -> do
        bracket_ (do Session s <- getConnectionSession conn
                     rc <- c_ha_state_init s
                     when (rc /= 0) $ error "failed to initialize ha_state")
                 c_ha_state_fini
                 f

withEndpoint :: RPCAddress -> (ServerEndpoint -> IO a) -> IO a
withEndpoint addr = bracket
    (listen addr listenCallbacks)
    stopListening
  where
    listenCallbacks = ListenCallbacks
      { receive_callback = \it _ -> do
          hPutStr stderr "Received: "
          print =<< unsafeGetFragments it
          return True
      }
#endif

systemHostname :: String
systemHostname = unsafePerformIO getHostName
