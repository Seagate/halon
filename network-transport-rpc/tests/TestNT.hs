import Network.Transport.RPC ( createTransport, rpcAddress, defaultRPCParameters
                             , RPCTransport(..)
                             )
import Network.Transport.Tests

main :: IO ()
main = do
  testTransport $ fmap Right $ fmap networkTransport $
      createTransport "s1" (rpcAddress "0@lo:12345:34:2") defaultRPCParameters
