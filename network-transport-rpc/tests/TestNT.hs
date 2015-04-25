import Mero (withM0)
import Network.Transport
import Network.Transport.RPC ( createTransport, rpcAddress, defaultRPCParameters
                             , RPCTransport(..)
                             )
import Network.Transport.Tests

main :: IO ()
main = withM0 $ do
  transport <- fmap networkTransport $
      createTransport "s1" (rpcAddress "0@lo:12345:34:2") defaultRPCParameters
  testTransport $ return $ Right transport
  closeTransport transport
