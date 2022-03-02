-- |
-- Copyright : (C) 2013 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
--
module HA.Multimap.Tests ( tests ) where

import HA.Multimap.Implementation

import Control.Exception (AssertionFailed(..), throwIO)
import Data.ByteString.Char8 ( pack )
import Data.List ( sort )
import Test.Framework

tests :: [TestTree]
tests =
    [ pureTest "toList.fromList"
       $ let [(b0',xs)] = toList $ fromList [(b0,[b1,b2]),(b0,[b3,b4])]
      in b0 == b0' && sort xs == [b1,b2,b3,b4]

    , pureTest "insertMany"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
          in fromList xs == insertMany xs empty

    , pureTest "insertMany2"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
             xs' = [(b1,[b5])]
          in fromList (xs ++ xs') == insertMany xs' mm

    , pureTest "insertMany3"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
             xs' = [(b5,[])]
          in fromList (xs ++ xs') == insertMany xs' mm

    , pureTest "deleteValues"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
             xs' = [(b5,[])]
          in fromList xs == deleteValues xs' mm

    , pureTest "deleteValues2"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
             xs' = [(b1,[])]
          in fromList xs == deleteValues xs' mm

    , pureTest "deleteValues3"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
             xs' = [(b1,[b3])]
          in fromList [(b0,[b1,b2]),(b1,[b4])] == deleteValues xs' mm

    , pureTest "deleteValues4"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
             xs' = [(b1,[b3,b4])]
          in fromList [(b0,[b1,b2]),(b1,[])] == deleteValues xs' mm

    , pureTest "deleteKeys"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
          in fromList xs == deleteKeys [b5] mm

    , pureTest "deleteKeys2"
       $ let xs = [(b0,[b1,b2]),(b1,[b3,b4])]
             mm = insertMany xs empty
          in fromList (take 1 xs) == deleteKeys [b1] mm
    ]
  where
    pureTest s b = testSuccess s $
        if b then return () else throwIO $ AssertionFailed s

    b0:b1:b2:b3:b4:b5:_ = map (pack . ('b':) . show) [(0::Int)..]
