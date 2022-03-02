-- |
-- Copyright : (C) 2014 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
-- This modules defines functions to communicate with the
-- REST API of Docker
--
-- Configuration is taken from the environment variables
--
{-# Language LambdaCase        #-}
{-# Language PatternGuards     #-}
{-# Language OverloadedStrings #-}
module Control.Distributed.Commands.Docker
    ( newContainer
    , destroyContainer
    , showContainer
    , Credentials(..)
    , getCredentialsFromEnv
    , ContainerData(..)
    , NewContainerArgs(..)
    ) where

import Prelude hiding ( (<$>) )
import Control.Applicative ( (<$>) )
import Control.Distributed.Commands.Internal.Probes (waitPing, waitSSH)
import Control.Exception (throwIO)
import Control.Monad (void)
import Data.Aeson (Value(..), decode)
import Data.Aeson.Encode.Pretty (encodePretty)
import qualified Data.ByteString.Lazy.Char8 as BL8 (unpack, pack)
import qualified Data.HashMap.Strict as HM (lookup)
import Data.Text (unpack)
import System.Environment (lookupEnv)
import System.Process (readProcess)



-- API key and client ID
data Credentials = Credentials { dockerHost :: String }

-- Gets credentials from the environment variable
-- @DOCKER_HOST@.
getCredentialsFromEnv :: IO (Maybe Credentials)
getCredentialsFromEnv = do
  docker_host <- lookupEnv "DOCKER_HOST"
  return $ Credentials <$> docker_host

data NewContainerArgs = NewContainerArgs
    { image_id    :: String
    }

data ContainerData = ContainerData
    { containerId     :: String
    , containerIP     :: String
    }
  deriving (Show, Eq)

-- | Creates a container.
newContainer :: Credentials -> NewContainerArgs -> IO ContainerData
newContainer credentials args = do
    let
      json = "{\"Image\":\"" ++ (image_id args) ++ "\", " ++
                "\"HostConfig\": {\"Privileged\": true}}"
    callCURLPost json (dockerHost credentials ++ "/containers/create")
           >>= \case
      r | Just (Object obj)       <- decode (BL8.pack r)
        , Just (String st)        <- HM.lookup "Id" obj
        -> do
              -- container created - now start it
              void $ callCURLPost "" (dockerHost credentials ++ "/containers/" ++ (unpack st) ++ "/start")

              containerData <- showContainer credentials (unpack st)

              waitPing (containerIP containerData)
              waitSSH (containerIP containerData)

              return containerData

      r -> throwIO $ userError $ "newContainer error: " ++ showResponse r

-- Converts the response to a string, pretty printing it if
-- it is valid JSON.
showResponse :: String -> String
showResponse r =
    case decode $ BL8.pack r of
      Just v -> BL8.unpack (encodePretty (v :: Value))
                ++ "\n"
                ++ show v
      Nothing -> r

-- | Takes a container ID and returns the container data.
-- eg  http://172.17.0.17:8877/containers/19e12d14937358af28fe6efcb4048021552938b95a312db1a18907b476f71b4f/json
showContainer :: Credentials -> String -> IO ContainerData
showContainer credentials cid = do
    callCURLGet ((dockerHost credentials) ++ "/containers/" ++ cid ++ "/json"
                ) >>= \case
      r | Just (Object obj)       <- decode (BL8.pack r)
        , Just (Object ns)        <- HM.lookup "NetworkSettings" obj
        , Just (String cIP)       <- HM.lookup "IPAddress" ns
        -> return $ ContainerData cid (unpack cIP)

      r -> throwIO $ userError $ "showContainer error: " ++ showResponse r

-- | Destroys a container given its ID.
destroyContainer :: Credentials -> String -> IO ()
destroyContainer credentials cId = do
--    void $ callCURLPost "" ((dockerHost credentials) ++ "/containers/" ++ cId
--                            ++ "/kill" )
    void $ callCURLDelete $ (dockerHost credentials) ++ "/containers/" ++ cId ++
                            "?force=true"

callCURLPost :: String -> String -> IO String
callCURLPost input url = readProcess "curl" ["-s", "--data", "@-", url, "-H", "Content-Type: application/json"] input

callCURLGet :: String -> IO String
callCURLGet url = readProcess "curl" ["-s", url] ""

callCURLDelete :: String -> IO String
callCURLDelete url = readProcess "curl" ["--request", "DELETE", "-s", url] ""
