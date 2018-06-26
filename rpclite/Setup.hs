import Distribution.PackageDescription
import Distribution.Simple
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Program
import Distribution.Simple.Setup
import Distribution.Verbosity (normal)
import System.Environment

main = defaultMainWithHooks $ simpleUserHooks {
    hookedPrograms = [simpleProgram "m0ff2c"]
  , buildHook = rpclite_build
}

rpclite_build :: PackageDescription
              -> LocalBuildInfo
              -> UserHooks
              -> BuildFlags
              -> IO ()
rpclite_build pd lbi uh bf@(BuildFlags { buildVerbosity = vf }) = do
  mero_root <- lookupEnv "M0_SRC_DIR"
  let v = fromFlagOrDefault normal vf
      ff2c = fmap (++ "/xcode/ff2c/m0ff2c") mero_root
      progdb = userMaybeSpecifyPath "m0ff2c" ff2c $ withPrograms lbi
  (prog, _) <- requireProgram v (simpleProgram "m0ff2c") progdb
  rawSystemProgram v prog ["rpclite/rpclite_fop.ff"]
  (buildHook simpleUserHooks) pd lbi uh bf
