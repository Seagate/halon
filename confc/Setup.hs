import Distribution.PackageDescription
import Distribution.Simple
import Distribution.Simple.LocalBuildInfo
import Distribution.Simple.Program
import Distribution.Simple.Setup
import System.Exit (exitWith)
import System.Process (rawSystem)

main = defaultMainWithHooks $ simpleUserHooks
    { testHook = confc_test
    }

confc_test :: PackageDescription
           -> LocalBuildInfo
           -> UserHooks
           -> TestFlags
           -> IO ()
confc_test _ lbi _ _ =
    rawSystem "./cabal_test.sh" [ buildDir lbi ] >>= exitWith
