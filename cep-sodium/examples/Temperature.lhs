-- |
-- Copyright: (C) 2014 Tweag I/O Limited
-- 
-- A more complicated example, in which temperature signals from a
-- variety of nodes are averaged.
-- 

Problem statement:
  A pool is formed of n nodes, which may leave or join the pool at any time.
  Create a component that is responsible for tracking the average temperature
  of the pool over the last three seconds.

> {-# LANGUAGE DeriveDataTypeable         #-}
> {-# LANGUAGE GeneralizedNewtypeDeriving #-}

> module Main where

We will need a broker to transport publish and subscribe events
between nodes that might be interested in them.  Here, since
broadcasting is unacceptable, we will use the ‘centralized’ broker,
which is a node at a known address through which all requests can be
routed.  We will want access to various parts of Cloud Haskell in
order to be able to spawn the broker.

> import Network.CEP.Broker.Centralized (broker)
> import Control.Distributed.Process.Node
>   (newLocalNode, forkProcess, initRemoteTable)

We use the Sodium FRP frontend to CEP, along with some utility
functions for dealing with clock time.

> import Network.CEP.Processor.Sodium
> import FRP.Sodium
> import FRP.Sodium.Util (timeLoop, averageOver)

We will need to set up a transport over which the components can
communicate.  For the purposes of this example we use a TCP transport.

> import Network.Transport.TCP (createTransport, defaultTCPParameters)

We will be running multiple nodes on the same physical machine, so we
want the implementation to schedule them for us.

> import Control.Concurrent (forkIO, threadDelay)

We use lenses for field accessors.

> import Control.Lens

In order for a value to be published over the network, it needs to be
both Binary and Typeable.

> import Data.Binary (Binary)
> import Data.Typeable (Typeable)

Assorted imports.

> import Control.Applicative ((<$>), liftA2)
> import Control.Monad (void, forM_)
> import qualified Data.Map as Map
> import Data.Time.Clock (getCurrentTime, UTCTime)

We begin by defining the types of the events we want to work with.
Temperature represents the temperature of a node or pool;
AverageTemperature is the type we use to transmit the averaged
temperature.  We could split Temperature up into PoolTemperature and
NodeTemperature, for clarity; however, since nothing publishes a
PoolTemperature event, it isn't necessary.  These both derive Binary
and Typeable, so they can be published or subscribed to, as well as
some other instances for convenience.

> newtype Temperature = Temperature Double
>   deriving (Typeable, Binary, Show, Eq, Ord, Num, Fractional)

> newtype AverageTemperature = AverageTemperature Temperature
>   deriving (Typeable, Binary, Show, Eq, Ord, Num, Fractional)

A temperature source — i.e. a node in our imaginary pool.  For the
purpose of this example all our nodes will regularly broadcast a
constant temperature, but we could as easily make them more
complicated; in the real thing, we could expect the temperatures to
come from an IO action that reads a temperature sensor, for example.

> temperatureSource :: Temperature -> Event a -> Processor s ()
> temperatureSource temp time = publish $ const temp <$> time

This component is the solution to the problem statement, aggregating
all the temperature events into an average temperature.  The 'time'
parameter is a source of clock-time events; the value of each event is
the time that has elapsed since the previous event, in seconds.

> averageTemperature :: Behaviour UTCTime -> Processor s ()
> averageTemperature now = do

First we need a source of temperature events.  cep-sodium allows us to
simply write 'subscribe': the type of event to which we wish to
subscribe is determined by the inferred type of the expression, if
possible.  Here, the type of temperatureE is inferred to be `Event
(NetworkMessage Temperature)`, an event carrying a record with fields
`_source :: ProcessId` and `_payload :: Temperature`, and therefore we
request a subscription for events of type 'Temperature'.

>   temperatureE <- subscribe

Now temperatureE is just a normal Sodium event, and we can use the
'liftReactive' primitive use Sodium to define the network of
transformations through which the event should be pushed.

>   avg <- liftReactive $ do

First we want an internal representation of the state of the pool.  We
store it as a Data.Map.Map ProcessId Temperature.  'accum' starts with
an initial state (empty) and modifies it when a new event comes in (by
inserting or overwriting the value at that key).  In a real-world
situation we would have a health monitor that also notifies us when
nodes go down; we can merge those events here by merging the event
with a different function that removes downed nodes from the Map.

>     currentTemperatures <- accum Map.empty $
>       liftA2 Map.insert (^. source) (^. payload) <$> temperatureE

The pool temperature at this moment is simply the 'mean' of the
temperatures of all the nodes we know about.

>     let poolTemperature = mean . Map.elems <$> currentTemperatures

And then we use the 'averageOver' function from sodium-utils to get
the staircase average of the pool temperature over the last three
seconds.  Note that we can increase the resolution here, if necessary,
by increasing the frequency of the real-time sampling event and
scaling up the number of samples correspondingly.

>     averageOver 3 now poolTemperature

Having defined the value we're interested in, we now just publish it
using the 'publish' primitive, wrapped up in the appropriate newtype
so it doesn't get confused with the individual node temperature
events.  'value' is a Sodium primitive that discretizes a continuous
internal state, allowing us to only publish it when it changes.

>   publish $ AverageTemperature <$> value avg

This is not strictly necessary according to the problem statement, but
it's nice to print out the current average temperature for viewing
purposes.  Putting it into a separate node also serves as an example
of how to write ‘sink’ processes that take input and merely do
something with it rather than transforming it to output: namely, we
use Sodium's 'listen' primitive to register an IO handler for the
event that should be called whenever the event fires.

Unfortunately we need to add a type annotation here, as the intended
type is not clear from 'print' alone.

> averageSink :: Processor s ()
> averageSink = do
>   avg <-
>     subscribe :: Processor s (Event (NetworkMessage AverageTemperature))
>   liftReactive . void . flip listen print $
>     (^. payload) <$> avg

A simple mean function, which ascribes a mean of 0 to an empty set of
data points.

> mean :: Fractional a => [a] -> a
> mean [] = 0
> mean xs = sum xs / fromIntegral (length xs)

In main we merely set up and run all the different nodes.  Notably, in
addition to the components described above, we require a 'broker'
component to pass requests between the other nodes.  One
implementation of such a process is provided by the cep package, which
is what we use here.

> main :: IO ()
> main = do

First, we must create a transport on which the nodes can communicate;
here we use TCP.

>   Right transport <- createTransport "127.0.0.1" "8898" defaultTCPParameters

Now we start a centralized broker, which is as simple as calling
'Network.CEP.Broker.Centralized.startBroker'.

>   brokerPid <- newLocalNode transport initRemoteTable
>                  >>= flip forkProcess broker

Some of our components are interested in real time, so we create an
event that represents the time passed since the last sample here.  We
will pump it regularly with updated times using 'timeLoop' from
sodium-utils as the ‘main loop’ of our program.

The provided times are stored in a 'Behaviour' we call 'now'.

>   (time, pushTime) <- sync newEvent
>   now <- getCurrentTime >>= sync . flip hold time

Here we have the initial configuration of the CEP nodes, which simply
points them to the broker we just created.

>   let cfg = Config [brokerPid]

Now, for example purposes, we create four temperature sources 0–3,
which will each delay 4n + 1 seconds before joining the network and
beginning to transmit temperature events.

>   forM_ [0 .. 3] $ \n -> forkIO $ do
>     threadDelay $ (4 * n + 1) * 1000000
>     runProcessor transport cfg $
>       temperatureSource (Temperature $ fromIntegral n) time

Launch the averageTemperature and averageSink components.

>   _ <- forkIO $ runProcessor transport cfg (averageTemperature now)
>   _ <- forkIO $ runProcessor transport cfg averageSink

And now begin the program's ‘main loop’, pumping the 'time' event we
created earlier.

>   timeLoop 0.5 . const $ getCurrentTime >>= sync . pushTime

