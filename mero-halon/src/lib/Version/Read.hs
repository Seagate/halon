{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

-- |
-- Copyright : (C) 2016 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
-- Module to print Halon version information.

module Version.Read where

import Data.List (intercalate)
import Foreign.C.String (peekCAString)
import qualified Language.C.Inline as C
import Text.Printf (printf)
import Version

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
  return $ printf (intercalate "\n" [
        "Halon %s (Git revision: %s)"
      , "Authored on: %s"
      , "Built against:"
      , "Mero: %s (Git revision: %s) (Configure flags: %s)"
      , "Built on: %s"
      , "Running against:"
      , "Mero: %s (Git revision: %s) (Configure flags: %s)"
      , "Built on: %s"
      ])
    Version.gitDescribe Version.gitCommitHash Version.gitCommitDate
    mero_build_desc mero_build_version mero_build_opts mero_build_build_time
    mero_runtime_desc mero_runtime_version mero_runtime_opts mero_runtime_build_time
