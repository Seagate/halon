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
    { testHook = nt_rpc_test }

nt_rpc_test :: PackageDescription
            -> LocalBuildInfo
            -> UserHooks
            -> TestFlags
            -> IO ()
nt_rpc_test _ lbi _ _ =
    rawSystem "./cabal_test.sh" [ buildDir lbi ] >>= exitWith
