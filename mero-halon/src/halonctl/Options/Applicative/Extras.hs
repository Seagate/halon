-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--

module Options.Applicative.Extras
    ( withDesc
    , withFullDesc
    , cmd
    )
  where

import Prelude hiding ((<*>))
import Data.Monoid ((<>))
import Options.Applicative

withDesc :: Parser a -> String -> ParserInfo a
withDesc parser desc =
    info (helper <*> parser) $ progDesc desc

withFullDesc :: String -> Parser a -> String -> ParserInfo a
withFullDesc name parser desc =
    info (helper <*> parser) $
         header name
      <> progDesc desc
      <> fullDesc

cmd :: String -- ^ Command
    -> Parser a -- ^ Command parser
    -> String -- ^ Command description
    -> Mod CommandFields a
cmd c p dsc = command c (withDesc p dsc)
