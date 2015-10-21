{-# LANGUAGE TemplateHaskell #-}
module TH where

import Data.Traversable
import HA.ResourceGraph
import Language.Haskell.TH

resources :: Name -> ExpQ
resources n = do
    ClassI _ instances <- reify n
    listE $ map mk instances
  where
    mk (InstanceD [] (AppT (AppT (AppT _ (ConT r)) a) b) _) =
      tupE [stringE (show r), stringE (p a), stringE (p b)]
    p (ConT n) = show n
    p (AppT n m) = p n ++ "_" ++ p m
