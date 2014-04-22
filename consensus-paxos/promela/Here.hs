{-# OPTIONS_GHC -fno-warn-missing-fields #-}
module Here (here) where

import Language.Haskell.TH
import Language.Haskell.TH.Quote


here :: QuasiQuoter
here = QuasiQuoter { quoteExp = stringE }
