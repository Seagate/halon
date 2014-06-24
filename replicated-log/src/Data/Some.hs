{-# LANGUAGE CPP #-}
#if MIN_VERSION_base(4,7,0)
{-# LANGUAGE DeriveDataTypeable #-}
#endif
module Data.Some ( Some(..) ) where

#if MIN_VERSION_base(4,7,0)
import Data.Typeable ( Typeable )
#else
import Data.Typeable ( Typeable(..), Typeable1(..), mkTyCon3, mkTyConApp
                     , tyConPackage, tyConModule, typeRepTyCon
                     )
#endif


-- | An auxiliary type for hiding parameters of type constructors
data Some f = forall a. Some (f a)
#if MIN_VERSION_base(4,7,0)
                 deriving (Typeable)
#else
-- | The sole purpose of this type is to provide a typeable instance from
-- which to extract the package and the module name.
data T = T
 deriving Typeable

instance Typeable1 f => Typeable (Some f) where
  typeOf _ = mkTyCon3 packageName moduleName "Some"
             `mkTyConApp` [ typeOf1 (undefined :: f a) ]
    where
      packageName = tyConPackage $ typeRepTyCon $ typeOf T
      moduleName = tyConModule $ typeRepTyCon $ typeOf T
#endif


