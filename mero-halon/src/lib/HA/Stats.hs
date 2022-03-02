--
-- Copyright : (C) 2015 Seagate Technology Limited.
-- License   : Apache License, Version 2.0.
--

{-# LANGUAGE TemplateHaskell #-}
module HA.Stats where

import Control.Distributed.Process
import Control.Distributed.Process.Closure
import Control.Monad
import Data.List


-- | Send the peak resident set size in kBs in 'Integer' form to the given
-- process.
getStats :: ProcessId -> Process ()
getStats caller = do
    m <- liftIO $
      (fmap (drop 1 . words) . find ("VmHWM:" `isPrefixOf`) . lines)
        <$> readFile "/proc/self/status"
    usend caller $ join $ fmap readMem m
  where
    readMem :: [String] -> Maybe Integer
    readMem [num, "kB"] = case reads num of
      (i,_) : _ -> Just i
      _        -> Nothing
    readMem _           = Nothing

remotable ['getStats]
