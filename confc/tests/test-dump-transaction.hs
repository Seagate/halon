module Main
  where

import Mero (withM0)
import Mero.Spiel

import Test.MakeConf

localAddress :: String
localAddress = "0@tcp:12345:35:113"

main :: IO ()
main = do
  withM0 $ withTransactionDump "/dev/null" 1 $
    transaction "endpoint1@tcp:12345:30:1000" "endpoint2@tcp:12345:30:10001"
  putStrLn "OK"
