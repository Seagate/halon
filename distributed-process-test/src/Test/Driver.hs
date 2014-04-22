-- |
-- Copyright : (C) 2013 Xyratex Technology Limited.
-- License   : All rights reserved.
--
-- Main functions to run 'Test's.

module Test.Driver
    ( defaultMain
    , defaultMainWith
    ) where

import Test.Framework

import Text.Regex.Posix ((=~))
import System.Console.GetOpt
    ( OptDescr(..), ArgDescr(..), ArgOrder(..), getOpt, usageInfo )
import System.Exit ( exitFailure, exitSuccess )
import System.Environment ( getArgs, getProgName )
import Control.Monad ( foldM, when )
import Control.Arrow (second)

type TestName = String

data TestOption = TestOption
  { listTests :: Bool
  , showHelp :: Bool
  , testPatterns :: [String]
  } deriving (Eq, Show)

-- | Default option for running test.
defaultTestOption :: TestOption
defaultTestOption = TestOption
  { listTests = False
  , showHelp = False
  , testPatterns = []
  }

-- | Options for test runner.
optdescrs :: [OptDescr (TestOption -> TestOption)]
optdescrs =
    [ Option ['l'] ["list"]
      (NoArg $ \o -> o {listTests=True})
      "list available tests and exit"
    , Option ['h'] ["help"]
      (NoArg $ \o -> o {showHelp=True})
      "show help and exit"
    , Option ['p'] ["pattern"]
      (ReqArg (\re o -> o {testPatterns = re : testPatterns o}) "REGEX")
      "filter tests by regex pattern REGEX"
    ]

-- | Default main.
--
-- Takes a list of 'Test' and run them. The main function built with this
-- will display brief usage when @--help@ option were given.
--
defaultMain :: [Test] -> IO ()
defaultMain = defaultMainWith . const . return

-- | Like 'defaultMain', but for tests with extra argument
-- passed at the time of executable invocation. Instead of calling
-- 'getArgs', use this function when arguments from command line are
-- required.
--
-- Note that 'OptDescr' options @-h@, @--help@, @-l@, @--list@, and @-p@,
-- @--pattern@ are already used internally.
--
defaultMainWith ::
    ([String] -> IO [Test])
    -- ^ Action taking list of 'String' from stdarg and returning
    -- 'Test's to run.
    -> IO ()
defaultMainWith act = do
    args <- getArgs
    myName <- getProgName

    let (parsed, rest, errs) = getOpt Permute optdescrs args
        myOpts = foldr ($) defaultTestOption parsed
        myHeader = unlines
            [ "Usage: " ++ myName ++ " [OPTIONS]"
            , ""
            , "OPTIONS:"
            ]
        printUsage = putStrLn $ usageInfo myHeader optdescrs
        testFilter :: String -> Bool
        testFilter = let pats = testPatterns myOpts in case pats of
            [] -> const True
            _  -> \testName -> any (testName =~) pats

    tests <- act rest

    when (not $ null errs) $ do
        putStrLn "Error:"
        mapM_ (putStrLn . ("  " ++)) errs
        printUsage
        exitFailure

    when (showHelp myOpts) $ do
        printUsage
        exitSuccess

    when (listTests myOpts) $ do
        listAll tests
        exitSuccess

    foldM (runTest "" testFilter) [] tests >>= summarize
  where
    listAll = foldM (listOne "") ()
    listOne prefix _ t = case t of
        Test ti           -> putStrLn $ prefix ++ name ti
        Group gname _ ts  -> mapM_ (listOne (prefix ++ gname ++ "/") ()) ts
        ExtraOptions _ t' -> listOne prefix () t'

    runTest :: String -> (TestName -> Bool) -> [(TestName,Result)] -> Test
               -> IO [(TestName,Result)]
    runTest prefix filt acc (Test ti) = do
        let testName = prefix ++ name ti
        if filt testName then do
            r <- run ti
            putStr $ "Test " ++ testName ++ ":"
            case r of
                Finished res -> print res >> return ((testName,res):acc)
                _            -> error "Unhandled result type."
          else do
            return acc
    -- Ignoring 'concurrently' flag...
    runTest prefix filt acc (Group gname _conc ts) = do
        rs <- mapM (runTest (prefix ++ gname ++ "/") filt []) ts
        return $ concat rs ++ acc
    runTest _ _  _ _ = error "Unhandled test type."

    summarize :: [(TestName,Result)] -> IO ()
    summarize rs =
      if all (snd . second (== Pass)) rs then do
        putStrLn $ "All tests passed (exactly " ++ show (length rs) ++ ")."
        putStrLn "Test result: SUCCESS"
      else do
        let notPassed = filter (snd . second (/= Pass)) rs
        putStrLn $ "Some tests failed (" ++ show (length notPassed)
                                         ++ " of " ++ show (length rs) ++ ")."
        mapM_ putStrLn
            [ "Test \"" ++ n ++ "\" failed with " ++ show msg
            | (n, msg) <- notPassed ]
        putStrLn "Test result: FAIL"
        exitFailure
