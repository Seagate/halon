-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This modules defines functions to communicate with the
-- REST API of Digital Ocean.
--
-- Credentials are taken from the environment variables
--
{-# Language LambdaCase        #-}
{-# Language PatternGuards     #-}
{-# Language OverloadedStrings #-}
module Control.Distributed.Commands.DigitalOcean
    ( newDroplet
    , destroyDroplet
    , showDroplet
    , Credentials(..)
    , getCredentialsFromEnv
    , DropletData(..)
    , NewDropletArgs(..)
    ) where

import Control.Concurrent (threadDelay)
import Control.Distributed.Commands.Internal.Probes (waitPing, waitSSH)
import Control.Exception (throwIO)
import Control.Monad (liftM2, when)
import Data.Aeson (Value(..), decode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy.Char8 as BL8 (unpack, pack)
import qualified Data.HashMap.Strict as HM (lookup)
import Data.Maybe (isNothing)
import Data.Scientific (Scientific, floatingOrInteger)
import Data.Text (unpack)
import System.Environment (lookupEnv)
import System.Process (readProcess)

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

doURL :: String
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
    callCURLGet
      (doURL ++ "/droplets/new?" ++ credentialsToQueryString credentials
             ++ "&name="        ++ name args
             ++ "&size_slug="   ++ size_slug args
             ++ "&image_id="    ++ image_id args
             ++ "&region_slug=" ++ region_slug args
             ++ "&ssh_key_ids=" ++ ssh_key_ids args
           ) >>= \case
      r | Just (Object obj)       <- decode (BL8.pack r)
        , Just (String st)        <- HM.lookup "status" obj
        , st == "OK"
        , Just (Object d)         <- HM.lookup "droplet" obj
        , Just (Number dropletId) <- HM.lookup "id" d
        , Just (Number eventId) <- HM.lookup "event_id" d
        -> do waitForEventConfirmation credentials $
                showScientificId eventId
              dd <- showDroplet credentials $ showScientificId dropletId
              waitPing $ dropletDataIP dd
              waitSSH $ dropletDataIP dd
              return dd
      r -> throwIO $ userError $ "newDroplet error: " ++ showResponse r

-- Converts the response to a string, pretty printing it if
-- it is valid JSON.
showResponse :: String -> String
showResponse r =
    case decode $ BL8.pack r of
      Just v -> BL8.unpack (encodePretty (v :: Value))
                ++ "\n"
                ++ show v
      Nothing -> r

-- | Takes a droplet ID and returns the droplet data.
showDroplet :: Credentials -> String -> IO DropletData
showDroplet credentials dropletId = do
    callCURLGet (doURL ++ "/droplets/" ++ dropletId ++ "/"
                       ++ "?" ++ credentialsToQueryString credentials
                ) >>= \case
      r | Just (Object obj)       <- decode (BL8.pack r)
        , Just (String st)        <- HM.lookup "status" obj
        , st == "OK"
        , Just (Object d)         <- HM.lookup "droplet" obj
        , Just (String dropletIP) <- HM.lookup "ip_address" d
        , Just (String status)    <- HM.lookup "status" d
        -> return $ DropletData dropletId (unpack dropletIP) (unpack status)

      r -> throwIO $ userError $ "showDroplet error: " ++ showResponse r

-- | Destroys a droplet given its ID.
destroyDroplet :: Credentials -> String -> IO ()
destroyDroplet credentials dropletId = do
    callCURLGet (doURL ++ "/droplets/" ++ dropletId
                       ++ "/destroy?"  ++ credentialsToQueryString credentials
                ) >>= \case
      r | Just (Object obj)     <- decode (BL8.pack r)
        , Just (String st)      <- HM.lookup "status" obj
        , st == "OK"
        , Just (Number eventId) <- HM.lookup "event_id" obj
        -> waitForEventConfirmation credentials $ showScientificId eventId

      r -> throwIO $ userError $ "destroyDroplet error: " ++ showResponse r

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
    callCURLGet (doURL ++ "/events/" ++ eventId ++ "/"
                       ++ "?" ++ credentialsToQueryString credentials
                ) >>= \case
      r | Just (Object obj)         <- decode (BL8.pack r)
        , Just (String st)          <- HM.lookup "status" obj
        , st == "OK"
        , Just (Object d)           <- HM.lookup "event" obj
        , Just eventStatusJ         <- HM.lookup "action_status" d
        -> case eventStatusJ of
            String eventStatus -> return $ EventData $ Just $ unpack eventStatus
            Null               -> return $ EventData Nothing
            _                  ->
              throwIO $ userError $ "showEvent error: " ++ showResponse r

      r -> throwIO $ userError $ "showEvent error: " ++ showResponse r

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

-- XXX The digital ocean interface was first implemented with the haskell
-- bindings to libcurl. Implementation with v1.3.8 of bindings was crashing
-- sporadically, so we switched to using the curl command line tool.
callCURLGet :: String -> IO String
callCURLGet url = readProcess "curl" ["-s", url] ""
