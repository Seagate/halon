{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ViewPatterns #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
--
-- Entry point for halon-st.
module Main where

import qualified Data.Map.Strict as Map
import           Data.Monoid ((<>))
import qualified HA.ST.ClusterRunning
import           HA.ST.Common
import qualified Options.Applicative as Opt
import           System.Environment (getProgName)
import           System.IO (stderr, hPutStrLn)
import qualified Test.Tasty.HUnit as T
import qualified Test.Tasty as T
import qualified Test.Tasty.Options as TO
import Data.Proxy
import System.Exit

-- | List of tests to expose to the user. Add new tests here.
tests :: [HASTTest]
tests =
  [ HA.ST.ClusterRunning.test
  ]

-- | Look-up map for 'tests'.
testMap :: Map.Map String HASTTest
testMap = Map.fromList $ map (\v -> (_st_name v, v)) tests

main :: IO ()
main = do
  let ig = T.includingOptions [TO.Option (Proxy :: Proxy MaybeTest)]
  T.defaultMainWithIngredients (ig : T.defaultIngredients) . T.askOption $ \case
    -- ugly hack
    NoTest s -> noTest s
    NotSpecified -> bailOut
    YesTest t -> toTree t

bailOut :: T.TestTree
bailOut = T.testCase "no-test-given" .
  T.assertFailure $ "Test name not given, pick one of "
                 ++ show (Map.keys testMap)

noTest :: String -> T.TestTree
noTest s = T.testCase "no-such-test" .
  T.assertFailure $ "test not found: " ++ show s

toTree :: HASTTest -> T.TestTree
toTree t = T.testCase (_st_name t) $ _st_action t >>= \case
  Nothing -> return ()
  Just err -> T.assertFailure err

data MaybeTest = NoTest String
               | NotSpecified
               | YesTest HASTTest
  deriving (Show)
instance TO.IsOption MaybeTest where
  defaultValue = NotSpecified
  parseValue s = Just $ case Map.lookup s testMap of
    Nothing -> NoTest s
    Just t -> YesTest t
  optionName = return "test-name"
  optionHelp = return $ "Test name. One of " ++ show (Map.keys testMap)
