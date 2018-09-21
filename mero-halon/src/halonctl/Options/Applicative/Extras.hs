-- |
-- Copyright : (C) 2018 Xyratex Technology Limited.
-- License   : All rights reserved.
--

module Options.Applicative.Extras
  ( command'
  , withFullDesc
  ) where

import           Data.Semigroup ((<>))
import qualified Options.Applicative as O

withFullDesc :: String -> O.Parser a -> String -> O.ParserInfo a
withFullDesc name parser desc =
    O.info (O.helper <*> parser)
      $ O.header name
     <> O.progDesc desc
     <> O.fullDesc

command' :: String -> O.Parser a -> String -> O.Mod O.CommandFields a
command' name p = O.command name . O.info p . O.progDesc
