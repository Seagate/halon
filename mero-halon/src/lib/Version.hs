{-# LANGUAGE TemplateHaskell #-}

-- |
-- Module    : Version
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--
-- Module to print Halon version information.

module Version where

import Development.GitRev as GitRev

-- | git describe output
gitDescribe :: String
gitDescribe = $(GitRev.gitDescribe)

-- | git commit hash
gitCommitHash :: String
gitCommitHash = $(GitRev.gitHash)

-- | git commit date
gitCommitDate :: String
gitCommitDate = $(GitRev.gitCommitDate)
