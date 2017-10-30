{-# OPTIONS_GHC -Wall -Werror #-}
{-# LANGUAGE TemplateHaskell #-}
module TH where

import HA.ResourceGraph ()
import Language.Haskell.TH

resources :: Name -> ExpQ
resources name = do
    ClassI _ instances <- reify name
    listE $ map mk instances
  where
    mk (InstanceD _ _ (AppT (AppT (AppT _ (ConT r)) a) b) []) =
        tupE $ map stringE [show r, p a, p b]
    mk _ = err "mk"

    p (ConT n) = show n
    p (AppT n m) = p n ++ "_" ++ p m
    p _ = err "p"

    err fname = error $ "resources." ++ fname ++ ": Unexpected argument"
