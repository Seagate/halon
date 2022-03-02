-- |
-- Copyright : (C) 2014-2018 Seagate Technology LLC and/or its Affiliates.
-- License   : Apache License, Version 2.0.
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
