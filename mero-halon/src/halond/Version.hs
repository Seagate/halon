{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP #-}

-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
-- Module to print Halon version information.

module Version where

import Data.List (intercalate)
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
    peekCAString =<< [C.exp| const char* { m0_build_info_get()->bi_git_describe } |]
  mero_runtime_desc <-
    peekCAString =<< [C.exp| const char* { M0_VERSION_GIT_DESCRIBE } |]
  mero_build_version <-
    peekCAString =<< [C.exp| const char* { m0_build_info_get()->bi_git_rev_id } |]
  mero_runtime_version <-
    peekCAString =<< [C.exp| const char* { M0_VERSION_GIT_REV_ID } |]
  mero_build_opts <-
    peekCAString =<< [C.exp| const char* { m0_build_info_get()->bi_configure_opts } |]
  mero_runtime_opts <-
    peekCAString =<< [C.exp| const char* { M0_VERSION_BUILD_CONFIGURE_OPTS } |]
  return $ printf (intercalate "\n" [
        "Halon %s (Git revision: %s)"
      , "Built against:"
      , "Mero: %s (Git revision: %s) (Configure flags: %s)"
      , "Running against:"
      , "Mero: %s (Git revision: %s) (Configure flags: %s)"
      ])
    ($(gitDescribe) :: String) ($(gitHash) :: String)
    mero_build_desc mero_build_version mero_build_opts
    mero_runtime_desc mero_runtime_version mero_runtime_opts

#else
versionString :: IO String
versionString =
  return $ printf (intercalate "\n" [
        "Halon %s (Git revision: %s)"
      , "Built without Mero integration."
      ])
    ($(gitDescribe) :: String) ($(gitHash) :: String)
#endif
