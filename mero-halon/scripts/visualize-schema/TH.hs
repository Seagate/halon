{-# OPTIONS_GHC -Wall -Werror #-}
{-# LANGUAGE TemplateHaskell #-}
module TH
  ( RelationInfo(..)
  , resources
  , sep
  ) where

import HA.ResourceGraph (Cardinality, cardinalities)
import Data.Proxy (Proxy(..))
import Language.Haskell.TH

data RelationInfo = RelationInfo
  { riFrom :: String
  , riBy :: String
  , riTo :: String
  , riCardFrom :: Cardinality
  , riCardTo :: Cardinality
  } deriving Show

resources :: Name -> ExpQ
resources name = do
    ClassI _ instances <- reify name
    listE $ map mk instances
  where
    mk :: Dec -> ExpQ
    mk (InstanceD _ _ (AppT (AppT (AppT _ r@(ConT _)) a) b) []) = do
        let c = [| cardinalities (Proxy :: Proxy $(pure r))
                                 (Proxy :: Proxy $(pure a))
                                 (Proxy :: Proxy $(pure b))
                 |]
        [| RelationInfo { riFrom = $(reprQ a)
                        , riBy = $(reprQ r)
                        , riTo = $(reprQ b)
                        , riCardFrom = fst $c
                        , riCardTo = snd $c
                        }
         |]
    mk d = err "mk" d

    reprQ :: Type -> ExpQ
    reprQ = stringE . repr

    repr :: Type -> String
    repr (ConT n) = show n
    repr (AppT n m) = repr n ++ sep : repr m
    repr t = err "repr" t

    err :: Show a => String -> a -> b
    err func arg =
        error $ "[resources." ++ func ++ "] Unexpected argument: " ++ show arg

-- | Separator character, placed between components of a binary
-- type constructor in its DOT representation.
-- E.g., type `Service PingConf` will be shown as `"Service-PingConf"`.
sep :: Char
sep = '-'
