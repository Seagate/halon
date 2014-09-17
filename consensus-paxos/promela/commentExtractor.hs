-- This program extracts fragments from files specified in the standard
-- input.
--
-- To get help type
--
-- > runhaskell commentExtractor.hs
--

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE QuasiQuotes #-}

import Here(here)

import Control.Monad ( forM )
import Data.Char ( isSpace, toUpper, isDigit )
import Data.Function ( on )
import Data.List ( dropWhileEnd, sortBy )
import System.Environment ( getArgs )


takeComments :: String -> String -> Bool -> [String] -> [(Int,[String])]
takeComments filename keyword insertLine = go 0
  where
    go !i xs =
      case break (cmpKeyword keyword) xs of
        (pfx,start:ps) -> case break ((\s -> "-}" == s || "*-}" == s) . trim) ps of
           (ps',rest) -> case i + length pfx of
              !i' -> ( readPos start
                     , if insertLine
                       then ("#line " ++ show (i'+2) ++ ' ' : show filename) : ps'
                       else ps'
                     )
                     : go (i' + 1 + length ps') rest
        (_,[]) -> []

    cmpKeyword k = (("{-*" ++ (map toUpper k))==)
                 . map toUpper . takeWhile (not . isSpace)
    readPos s = case takeWhile isDigit
                     $ dropWhile isSpace
                     $ dropWhile (not . isSpace) s of
                  [] -> 100
                  ds -> read ds

trim :: String -> String
trim = dropWhile isSpace . dropWhileEnd isSpace

main :: IO ()
main = do
  args <-  getArgs
  case args of
   keyword:rs ->
     fmap (map trim . lines) getContents
       >>= mapM (\f -> fmap (takeComments f keyword (null rs) . lines)
                            $ readFile f
                )
         >>= putStrLn . init . unlines . concat . map snd
                      . sortBy (compare `on` fst) . concat
   _ ->
     putStrLn [here|
NAME
       commentExtractor - Extracts comments from Haskell files.

SYNAPSIS
       runhaskell commentExtractor.hs <keyword> [-x]

DESCRIPTION
       This program takes a list of files from standard input, one file per
       line, and prints to stdout fragments extracted from each of them.

       Fragments are of the form

       {-*<keyword>
       fragment contents
       *-}

       where <keyword> is the keyword supplied in the command line. Delimiters
       "{-*<keyword>" and "*-}" are not included in the output.

       Additionally, the keyword may be followed by a natural number which
       defaults to 100 when missing. As in:

       {-*<keyword> 100
       fragment contents
       *-}

       Fragments from all files are sorted by this number in ascending order
       before printing them to stdout.

OPTIONS
       -x If present, #line pragmas are suppressed in the output. This will make
          tools reading the output to refer to locations in the output rather
          than locations in the original files.
|]
