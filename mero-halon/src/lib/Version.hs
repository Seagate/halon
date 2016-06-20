{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE RecordWildCards #-}

-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
-- Module to print Halon version information.

module Version (versionString) where

import Data.List (intercalate)
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime, iso8601DateFormat)
import Development.GitRev

import Text.Printf (printf)

#ifdef USE_MERO
import Foreign.C.String (peekCAString)

import qualified Language.C.Inline as C

C.include "mero/version.h"

-- | Show version information
versionString :: IO String
versionString = do
  mero_build_desc <-
    peekCAString =<< [C.exp| const char* { M0_VERSION_GIT_DESCRIBE } |]
  mero_runtime_desc <-
    peekCAString =<< [C.exp| const char* { m0_build_info_get()->bi_git_describe } |]
  mero_build_version <-
    peekCAString =<< [C.exp| const char* { M0_VERSION_GIT_REV_ID } |]
  mero_runtime_version <-
    peekCAString =<< [C.exp| const char* { m0_build_info_get()->bi_git_rev_id } |]
  mero_build_opts <-
    peekCAString =<< [C.exp| const char* { M0_VERSION_BUILD_CONFIGURE_OPTS } |]
  mero_runtime_opts <-
    peekCAString =<< [C.exp| const char* { m0_build_info_get()->bi_configure_opts } |]
  mero_build_build_time <-
    peekCAString =<< [C.exp| const char* { M0_VERSION_BUILD_TIME } |]
  mero_runtime_build_time <-
    peekCAString =<< [C.exp| const char* { m0_build_info_get()->bi_time } |]
  Version{..} <- version
  return $ printf (intercalate "\n" [
        "Halon %s (Git revision: %s)"
      , "Built on: %s"
      , "Built against:"
      , "Mero: %s (Git revision: %s) (Configure flags: %s)"
      , "Built on: %s"
      , "Running against:"
      , "Mero: %s (Git revision: %s) (Configure flags: %s)"
      , "Built on: %s"
      ])
    describe commit (formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M:%S")) date)
    mero_build_desc mero_build_version mero_build_opts mero_build_build_time
    mero_runtime_desc mero_runtime_version mero_runtime_opts mero_runtime_build_time

#else
versionString :: IO String
versionString = do
  Version{..} <- version
  return $ printf (intercalate "\n" [
        "Halon %s (Git revision: %s)"
      , "Built on: %s"
      , "Built without Mero integration."
      ])
    describe commit (formatTime defaultTimeLocale (iso8601DateFormat (Just "%H:%M:%S")) date)
#endif

data Version = Version {
    describe :: String
  , commit :: String
  , date :: UTCTime
}

version :: IO Version
version = do
    time <- getCurrentTime
    return $ Version {
        describe = $(gitDescribe)
      , commit = $(gitHash)
      , date = time
      }