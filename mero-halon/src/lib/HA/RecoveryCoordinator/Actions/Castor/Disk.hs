module  HA.RecoveryCoordinator.Actions.Castor.Disk
  ( attachDisk
  , detachDisk
  ) where

import Data.Foldable (traverse_)
import Data.Functor (void)

import HA.RecoveryCoordinator.Actions.Core
import HA.RecoveryCoordinator.Actions.Mero.Conf
import HA.RecoveryCoordinator.Actions.Mero.Spiel
import qualified HA.Resources.Mero as M0
import           HA.Resources.Mero.Note (showFid)

import Network.CEP

import qualified Mero.Spiel as Spiel

-- | Ask mero (IO services) to attach certain disk. In case if
-- 'sdev' for the disk is not found - this call is noop.
attachDisk :: M0.SDev -> PhaseM LoopState a ()
attachDisk sdev = do
  phaseLog "spiel"    $ "Attaching disk."
  phaseLog "disk.fid" $ show $ M0.fid sdev
  mdisk <- lookupSDevDisk sdev
  case mdisk of
    Just d ->
      void $ withSpielRC $ \sp m0 -> withRConfRC sp -- FIXME do not hide exception
        $ m0 $ Spiel.deviceAttach sp (M0.fid d)
    Nothing ->
      phaseLog "warning" $ "Disk for found for " ++ showFid sdev ++ " ignoring."

-- | Ask mero (IO services) to attach certain disk. In case if
-- 'sdev' for the disk is not found - this call is noop.
detachDisk :: M0.SDev -> PhaseM LoopState a ()
detachDisk sdev = do
  phaseLog "spiel" $ "Detaching disk"
  phaseLog "disk.fid" $ show $ M0.fid sdev
  mdisk <- lookupSDevDisk sdev
  case mdisk of
    Just d  ->
      void $ withSpielRC $ \sp m0 -> withRConfRC sp -- FIXME do not hide exception
        $ m0 $ Spiel.deviceDetach sp (M0.fid d)
    Nothing ->
      phaseLog "warning" $ "Disk for found for " ++ showFid sdev ++ " ignoring."
