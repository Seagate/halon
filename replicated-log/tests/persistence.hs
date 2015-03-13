{-# LANGUAGE OverloadedStrings #-}

-- |
-- Copyright : (C) 2015 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Tests of the persistence backends.

import Test.Driver
import Test.Tasty.Environment
import Test.Framework

import Control.Distributed.Log.Persistence as P
import Control.Distributed.Log.Persistence.LevelDB
import Control.Exception
import Data.Maybe
import Data.String


main :: IO ()
main = do
   (testArgs, runnerArgs) <- parseArgs
   defaultMainWithArgs testTree
                       (testArgs `orDefault` ["--num-threads","1", "-t", "5"])
                       runnerArgs

orDefault :: [a] -> [a] -> [a]
orDefault [] x = x
orDefault x  _ = x

testTree :: [String] -> IO TestTree
testTree _ = return $ testGroup "persistence"
               [ testGroup "LevelDB" $
                   tests $ openPersistentStore "store/subdir"
               ]

tests :: IO PersistentStore -> [TestTree]
tests newStore =
    [ testSuccess "can reopen store" . withTmpDirectory $ do
        newStore >>= close
        newStore >>= close

    , testSuccess "values in a map can be retrieved" . withTmpDirectory $ do

        bracket newStore close $ \db -> do
          m <- getMap db "map"
          atomically db [ Insert m (-2) "test -2", Insert m (-1) "test -1" ]
          atomically db [ Insert m 1 "test 1", Insert m 0 "test 0" ]

          m1 <- getMap db "map"
          let expected = [ "test -2", "test -1", "test 0", "test 1" ]
          contents <- fmap catMaybes $ mapM (P.lookup m1) [ (-2) .. 2 ]
          True <- return $ contents == expected
          contents' <- pairsOfMap m
          True <- return $ contents' == zip [ (-2), (-1), 0, 1 ] expected
          return ()

    , testSuccess "values in a map are persisted" . withTmpDirectory $ do

        bracket newStore close $ \db -> do
          m <- getMap db "map"
          atomically db [ Insert m (-2) "test -2", Insert m (-1) "test -1" ]
          atomically db [ Insert m 2 "test 2", Insert m 1 "test 1" ]

        bracket newStore close $ \db -> do
          m <- getMap db "map"
          let expected = [ "test -2", "test -1", "test 1", "test 2" ]
          contents <- fmap catMaybes $ mapM (P.lookup m) [ (-2) .. 2 ]
          True <- return $ contents == expected
          contents' <- pairsOfMap m
          True <- return $ contents' == zip [ (-2), (-1), 1, 2 ] expected
          return ()

    , testSuccess "values in a map are trimmed (-1)" . withTmpDirectory $ do

        bracket newStore close $ \db -> do
          m <- getMap db "map"
          atomically db [ Insert m (-2) "test -2", Insert m (-1) "test -1" ]
          atomically db [ Insert m 2 "test 2", Insert m 1 "test 1"
                        , Trim m (-1)
                        ]

          let expected = [ "test -1", "test 1", "test 2" ]
          contents <- fmap catMaybes $ mapM (P.lookup m) [ (-2) .. 2 ]
          True <- return $ contents == expected
          contents' <- pairsOfMap m
          True <- return $ contents' == zip [ (-1), 1, 2 ] expected
          return ()

    , testSuccess "values in a map are trimmed (2)" . withTmpDirectory $ do

        bracket newStore close $ \db -> do
          m <- getMap db "map"
          atomically db [ Insert m (-2) "test -2", Insert m (-1) "test -1" ]
          atomically db [ Insert m 2 "test 2", Insert m 1 "test 1" ]
          atomically db [ Trim m 2 ]

          [ "test 2" ] <- fmap catMaybes $ mapM (P.lookup m) [ (-2) .. 2 ]
          [(2, "test 2")] <- pairsOfMap m
          return ()

    , testSuccess "values in another map are no trimmed" . withTmpDirectory $ do

        bracket newStore close $ \db -> do
          m <- getMap db "map"
          m1 <- getMap db "map1"
          atomically db [ Insert m (-2) "test -2", Insert m1 (-1) "test -1" ]
          atomically db [ Insert m1 2 "test 2", Insert m 1 "test 1" ]
          atomically db [ Trim m 2 ]

          [] <- fmap catMaybes $ mapM (P.lookup m) [ (-2) .. 2 ]
          [] <- pairsOfMap m
          [ "test -1", "test 2" ] <-
              fmap catMaybes $ mapM (P.lookup m1) [ (-2) .. 2 ]
          [ ((-1), "test -1"), (2, "test 2") ] <- pairsOfMap m1
          return ()

    , testSuccess "many values are trimmed" . withTmpDirectory $ do
        bracket newStore close $ \db -> do
          m <- getMap db "map"
          atomically db
            [ Insert m i (fromString $ "test " ++ show i) | i <- [0..10000] ]
          atomically db [ Trim m 10000 ]

          ["test 10000"] <- fmap catMaybes $ mapM (P.lookup m) [ 9990 .. 10000 ]
          [(10000, "test 10000")] <- pairsOfMap m
          return ()
     ]
