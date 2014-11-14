import Distribution.PackageDescription
import Distribution.Simple
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Program
import Distribution.Simple.Setup
import Distribution.Verbosity (normal)
import System.Environment
import System.Exit (exitWith)
import System.Process (rawSystem)

main = defaultMainWithHooks $ simpleUserHooks
    { hookedPrograms = [simpleProgram "ff2c"]
    , buildHook = nt_rpc_build
    , testHook = nt_rpc_test
    }

nt_rpc_build :: PackageDescription
              -> LocalBuildInfo
              -> UserHooks
              -> BuildFlags
              -> IO ()
nt_rpc_build pd lbi uh bf@(BuildFlags { buildVerbosity = vf }) = do
    mero_root <- lookupEnv "MERO_ROOT"
    let v = fromFlagOrDefault normal vf
        ff2c = fmap (++ "/xcode/ff2c/ff2c") mero_root
        progdb = userMaybeSpecifyPath "ff2c" ff2c $ withPrograms lbi
    (prog, _) <- requireProgram v (simpleProgram "ff2c") progdb
    rawSystemProgram v prog ["rpclite/rpclite_fop.ff"]
    (buildHook simpleUserHooks) pd lbi uh bf

nt_rpc_test :: PackageDescription
            -> LocalBuildInfo
            -> UserHooks
            -> TestFlags
            -> IO ()
nt_rpc_test _ lbi _ _ =
    rawSystem "./cabal_test.sh" [ buildDir lbi ] >>= exitWith
