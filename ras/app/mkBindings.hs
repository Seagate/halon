{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Generate bindings.

import           Data.Aeson.Schema
import           Data.Aeson.Schema.CodeGen
import           Data.Aeson.Schema.CodeGenM (Options(..), defaultOptions)
import           Data.Binary
import           Data.Hashable
import qualified Data.Map as M
import qualified Data.Text as T
import qualified Data.Text.IO as T
import           Data.Typeable
import           GHC.Generics
import           Language.Haskell.TH
import qualified RAS.Schemata.DisableRequest as DisableRequest
import qualified RAS.Schemata.FailureNotification as FailureNotification
import qualified RAS.Schemata.FailureSetQuery as FailureSetQuery
import qualified RAS.Schemata.FailureSetQueryResponse as FailureSetQueryResponse
import qualified RAS.Schemata.MessageAck as MessageAck
import qualified RAS.Schemata.Ping as Ping
import qualified RAS.Schemata.ProcessingError as ProcessingError



main :: IO ()
main = mapM_ (uncurry mkBindings) schemata
  where
    schemata =
      [ ("DisableRequest", DisableRequest.schema)
      , ("FailureNotification", FailureNotification.schema)
      , ("FailureSetQuery", FailureSetQuery.schema)
      , ("FailureSetQueryResponse", FailureSetQueryResponse.schema)
      , ("MessageAck", MessageAck.schema)
      , ("Ping", Ping.schema)
      , ("ProcessingError", ProcessingError.schema)
      ]

mkBindings :: T.Text -> Schema T.Text -> IO ()
mkBindings name schema = do
  let graph = M.singleton name schema
      appV f v = f defaultOptions ++ v
  (code, _) <- runQ $ generateModule
               ( "RAS.Bindings." `T.append` name)
               graph
               (defaultOptions { _extraModules = appV _extraModules ["RAS.Bindings.Instances ()"]
                               , _derivingTypeclasses =
                                   appV _derivingTypeclasses [''Generic, ''Typeable]
                               , _languageExtensions = [ "DeriveDataTypeable"
                                                       , "DeriveGeneric"
                                                       , "StandaloneDeriving" ]
                               , _extraInstances =
                                     \n -> [ instanceD (cxt []) (conT ''Binary `appT` conT n) []
                                           , instanceD (cxt []) (conT ''Hashable `appT` conT n) []
                                           ]
                               , _replaceModules = M.fromList
                                  [ ("Data.Hashable.Class", "Data.Hashable")
                                  , ("Data.Text.Show", "Data.Text") ]
                                  `M.union`
                                  _replaceModules defaultOptions
                               })
  T.writeFile ("src/RAS/Bindings/" ++ (T.unpack name) ++ ".hs")  code
