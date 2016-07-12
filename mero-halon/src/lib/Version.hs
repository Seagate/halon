{-# LANGUAGE TemplateHaskell #-}

-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
-- Module to print Halon version information.

module Version where

import Development.GitRev as GitRev

gitDescribe :: String
gitDescribe = $(GitRev.gitDescribe)

gitCommitHash :: String
gitCommitHash = $(GitRev.gitHash)

gitCommitDate :: String
gitCommitDate = $(GitRev.gitCommitDate)
