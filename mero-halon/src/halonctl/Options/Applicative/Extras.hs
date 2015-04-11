-- |
-- Copyright : (C) 2014 Xyratex Technology Limited.
-- License   : All rights reserved.
--

module Options.Applicative.Extras
    ( withDesc
    , withFullDesc
    )
  where

import Prelude hiding ((<*>))
import Options.Applicative
    ( (<*>)
    , (<>)
    , Parser
    , ParserInfo
    , fullDesc
    , header
    , helper
    , info
    , progDesc
    )

withDesc :: Parser a -> String -> ParserInfo a
withDesc parser desc =
    info (helper <*> parser) $ progDesc desc

withFullDesc :: String -> Parser a -> String -> ParserInfo a
withFullDesc name parser desc =
    info (helper <*> parser) $
         header name
      <> progDesc desc
      <> fullDesc
