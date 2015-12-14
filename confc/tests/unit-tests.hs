--
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
module Main where

import Test.Tasty
import Test.Tasty.HUnit

import Data.Monoid
import Foreign

import Mero
import Mero.ConfC
import qualified Language.C.Inline as C

C.context (C.baseCtx <> confCtx)
C.include "lib/bitmap.h"

main :: IO ()
main = do
  setNodeUUID Nothing
  withM0 $ defaultMain tests

tests :: TestTree
tests = testGroup "ut"
  [ testGroup "bitmap" 
      [ testCase "peek-poke == id" testPeekPoke
      , testCase "withBitmap works" testWithBitmap
      ]
  ]

testPeekPoke :: Assertion
testPeekPoke = alloca $ \bm_ptr -> do
  [C.block| void {
      struct m0_bitmap * bm = $(struct m0_bitmap* bm_ptr);
      m0_bitmap_init(bm, 32);
      m0_bitmap_set(bm, 0, true);
      m0_bitmap_set(bm, 1, false);
    }|]
  -- check old values as they are observable by C code
  cN    <- [C.exp| size_t { $(struct m0_bitmap* bm_ptr)->b_nr } |]
  cWord <- [C.exp| uint64_t { $(struct m0_bitmap *bm_ptr)->b_words[0] } |]
  bitmap@(Bitmap haskellN haskellWords)  <- peek bm_ptr
  -- check values as they are observable by Haskell
  assertEqual "Haskell read size correctly" cN (fromIntegral haskellN)
  assertEqual "Haskell read only one uint64_t element" 1 (length haskellWords)
  assertEqual "Haskell read data correctly" cWord (head haskellWords)
  -- poke value back
  poke bm_ptr bitmap
  -- test that value is still correct
  cNNew <- [C.exp| size_t { $(struct m0_bitmap* bm_ptr)->b_nr } |]
  assertEqual "Bitmap size after poke is correct" cN cNNew
  i <- [C.block| int {
          struct m0_bitmap * bm = $(struct m0_bitmap* bm_ptr);
          bool b=0;
          int ret=0;
          b = m0_bitmap_get(bm, 0);
          ret += b?1:0;
          b = m0_bitmap_get(bm, 0);
          ret += b?2:0;
          return ret;
        }|]
  assertEqual "Bitmap data after poke is correct" 3 i

testWithBitmap :: Assertion
testWithBitmap = withBitmap (bitmapFromArray [True, False]) $ \bm_ptr -> do
  cN    <- [C.exp| size_t { $(struct m0_bitmap* bm_ptr)->b_nr } |]
  assertEqual "Bitmap has correct size" 2 cN
  i <- [C.block| int {
          struct m0_bitmap * bm = $(struct m0_bitmap* bm_ptr);
          bool b=0;
          int ret=0;
          b = m0_bitmap_get(bm, 0);
          ret += b?1:0;
          b = m0_bitmap_get(bm, 0);
          ret += b?2:0;
          return ret;
        }|]
  assertEqual "Bitmap data is correct" 3 i
   
