-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- This modules defines functions to communicate with the
-- REST API of Digital Ocean.
--
-- Credentials are taken from the environment variables
--
{-# Language PatternGuards     #-}
{-# Language OverloadedStrings #-}
module Control.Distributed.Commands.DigitalOcean
    ( withDigitalOceanDo
    , newDroplet
    , destroyDroplet
    , showDroplet
    , Credentials
    , getCredentialsFromEnv
    , DropletData(..)
    , NewDropletArgs(..)
    ) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO, bracketOnError)
import Control.Monad (liftM2, when)
import Data.Aeson (Value(..), decode)
import Data.Aeson.Encode.Pretty (encodePretty)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy.Char8 as BL8 (unpack)
import qualified Data.HashMap.Strict as HM (lookup)
import Data.Maybe (isNothing)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (unpack)
import Network.Curl
    ( curlGetResponse_
    , CurlResponse_(..)
    , CurlCode(..)
    , withCurlDo
    , URLString
    )
import System.Environment (lookupEnv)
import System.IO (hGetLine, hClose, openFile, IOMode(..))
import System.Process
    ( terminateProcess
    , CreateProcess(..)
    , proc
    , StdStream(..)
    , createProcess
    )

-- Initializes resources to communicate with the digital ocean interface,
-- and releases these resources after the given action terminates.
--
-- This call is not thread-safe.
--
withDigitalOceanDo :: IO a -> IO a
withDigitalOceanDo = withCurlDo

-- API key and client ID
data Credentials = Credentials { clientId :: String, apiKey :: String }

-- Gets credentials from the environment variables
-- @DO_API_KEY@ and @DO_CLIENT_ID@.
getCredentialsFromEnv :: IO (Maybe Credentials)
getCredentialsFromEnv = liftM2 (liftM2 Credentials)
                          (lookupEnv "DO_CLIENT_ID")
                          (lookupEnv "DO_API_KEY")

credentialsToQueryString :: Credentials -> String
credentialsToQueryString credentials =
  "client_id=" ++ clientId credentials ++ "&api_key=" ++ apiKey credentials

doURL :: URLString
doURL = "https://api.digitalocean.com/v1"

-- | See @https://developers.digitalocean.com/v1/droplets/#new-droplet@
-- for the meaning of these arguments.
data NewDropletArgs = NewDropletArgs
    { name        :: String
    , size_slug   :: String
    , image_id    :: String
    , region_slug :: String
    , ssh_key_ids :: String
    }

data DropletData = DropletData
    { dropletDataId     :: String
    , dropletDataIP     :: String
    , dropletDataStatus :: String
    }
  deriving (Show, Eq)

-- | Creates a droplet.
newDroplet :: Credentials -> NewDropletArgs -> IO DropletData
newDroplet credentials args = do
    r <- curlGetResponse_
           (doURL ++ "/droplets/new?" ++ credentialsToQueryString credentials
                  ++ "&name="        ++ name args
                  ++ "&size_slug="   ++ size_slug args
                  ++ "&image_id="    ++ image_id args
                  ++ "&region_slug=" ++ region_slug args
                  ++ "&ssh_key_ids=" ++ ssh_key_ids args
           )
           []
    case respCurlCode r of
      CurlOK  | Just (Object obj)       <- decode (respBody r)
              , Just (String st)        <- HM.lookup "status" obj
              , st == "OK"
              , Just (Object d)         <- HM.lookup "droplet" obj
              , Just (Number dropletId) <- HM.lookup "id" d
              , Just (Number eventId) <- HM.lookup "event_id" d
              -> do waitForEventConfirmation credentials $
                      showScientificId eventId
                    dd <- showDroplet credentials $ showScientificId dropletId
                    waitPing $ dropletDataIP dd
                    -- Wait ten seconds before using the droplet othwerwise,
                    -- mysterious ssh failures would ensue.
                    threadDelay $ 10 * 1000000
                    return dd

      _      -> throwIO $ userError $ "newDroplet error: " ++ showResponse r

-- Converts the response to a string, pretty printing it if
-- it is valid JSON.
showResponse :: CurlResponse_ [(String,String)] ByteString -> String
showResponse r = show (respStatus r) ++ ": " ++
    case decode $ respBody r of
      Just v -> BL8.unpack (encodePretty (v :: Value))
                ++ "\n"
                ++ show v
      Nothing -> BL8.unpack $ respBody r

-- | Takes a droplet ID and returns the droplet data.
showDroplet :: Credentials -> String -> IO DropletData
showDroplet credentials dropletId = do
    r <- curlGetResponse_
           (doURL ++ "/droplets/" ++ dropletId ++ "/"
                  ++ "?" ++ credentialsToQueryString credentials
           )
           []
    case respCurlCode (r :: CurlResponse_ [(String, String)] ByteString) of
      CurlOK  | Just (Object obj)       <- decode (respBody r)
              , Just (String st)        <- HM.lookup "status" obj
              , st == "OK"
              , Just (Object d)         <- HM.lookup "droplet" obj
              , Just (String dropletIP) <- HM.lookup "ip_address" d
              , Just (String status) <- HM.lookup "status" d
              -> return $
                   DropletData dropletId (unpack dropletIP) (unpack status)

      _      -> throwIO $ userError $ "showDroplet error: " ++ showResponse r

-- | Destroys a droplet given its ID.
destroyDroplet :: Credentials -> String -> IO ()
destroyDroplet credentials dropletId = do
    r <- curlGetResponse_
           (doURL ++ "/droplets/" ++ dropletId
                  ++ "/destroy?"  ++ credentialsToQueryString credentials
           )
           []
    case respCurlCode (r :: CurlResponse_ [(String, String)] ByteString) of
      CurlOK  | Just (Object obj)       <- decode (respBody r)
              , Just (String st)        <- HM.lookup "status" obj
              , st == "OK"
              , Just (Number eventId) <- HM.lookup "event_id" obj
              -> waitForEventConfirmation credentials $ showScientificId eventId

      _      -> throwIO $ userError $ "destroyDroplet error: " ++ showResponse r

-- | Prints an integer without decimal point and places, other values are
-- printed with the 'Show' instance for 'Scientific'.
--
showScientificId :: Scientific -> String
showScientificId s = case floatingOrInteger s :: Either Double Integer of
    Left  _ -> show s
    Right i -> show i

data EventData = EventData { eventDataStatus :: Maybe String }
  deriving (Show, Eq)

-- | Takes an event ID and returns the event data.
showEvent :: Credentials -> String -> IO EventData
showEvent credentials eventId = do
    r <- curlGetResponse_
           (doURL ++ "/events/" ++ eventId ++ "/"
                  ++ "?" ++ credentialsToQueryString credentials
           )
           []
    case respCurlCode (r :: CurlResponse_ [(String, String)] ByteString) of
      CurlOK  | Just (Object obj)         <- decode (respBody r)
              , Just (String st)          <- HM.lookup "status" obj
              , st == "OK"
              , Just (Object d)           <- HM.lookup "event" obj
              , Just eventStatusJ <- HM.lookup "action_status" d
              -> case eventStatusJ of
                  String eventStatus -> return $ EventData $ Just $ unpack eventStatus
                  Null               -> return $ EventData Nothing
                  _                  ->
                    error $ "showEvent error: " ++ showResponse r

      _      -> throwIO $ userError $ "showEvent error: " ++ showResponse r

-- | Waits for an event with a given ID to be confirmed.
waitForEventConfirmation :: Credentials -> String -> IO ()
waitForEventConfirmation credentials eventId = do
    ev <- showEvent credentials eventId
    if isNothing $ eventDataStatus ev then do
      threadDelay $ 500 * 1000 -- wait 500 msec between retries
      waitForEventConfirmation credentials eventId
    else
      when (eventDataStatus ev /= Just "done") $
        throwIO $ userError $ "newDroplet error: " ++ show ev

-- | Waits until the given host replies to pings.
waitPing :: String -> IO ()
waitPing host =
    bracketOnError (openFile "/dev/null" ReadWriteMode) hClose $ \dev_null -> do
      (_, Just sout, ~(Just _), ph) <- createProcess (proc "ping" [ host ])
        { std_out = CreatePipe
        , std_err = UseHandle dev_null
        }
      -- We assume that the host has responded when ping prints two lines.
      _ <- hGetLine sout
      _ <- hGetLine sout
      terminateProcess ph
