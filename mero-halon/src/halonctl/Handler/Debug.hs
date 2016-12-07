{-# LANGUAGE RecordWildCards     #-}
-- |
-- Copyright : (C) 2016 Seagate Technology Limited.
-- License   : All rights reserved.
--
-- Querying Halon debugging information.

module Handler.Debug
  ( DebugOptions
  , parseDebug
  , debug
  ) where

import HA.EventQueue
import HA.RecoveryCoordinator.RC.Events.Debug
import Network.CEP (RuntimeInfoRequest(..), RuntimeInfo(..), MemoryInfo(..))

import Lookup

import Control.Applicative ((<|>))
import Control.Distributed.Process
import Control.Distributed.Process.Internal.Primitives
import Control.Monad (void, when)
import Control.Monad.Fix (fix)

import Data.Foldable (for_)
import qualified Data.Map as M
import Data.Maybe (isNothing)
import Data.Monoid ((<>))

import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

data DebugOptions =
    EQStats EQStatsOptions
  | RCStats RCStatsOptions
  | CEPStats CEPStatsOptions
  | NodStats NodeStatsOptions
  deriving (Eq, Show)

parseDebug :: O.Parser DebugOptions
parseDebug =
      ( EQStats <$> O.subparser ( O.command "eq" (O.withDesc parseEQStatsOptions
        "Print EQ statistics." )))
  <|> ( RCStats <$> O.subparser ( O.command "rc" (O.withDesc parseRCStatsOptions
        "Print RC statistics." )))
  <|> ( CEPStats <$> O.subparser ( O.command "cep" (O.withDesc parseCEPStatsOptions
        "Print CEP statistics." )))
  <|> ( NodStats <$> O.subparser ( O.command "node" (O.withDesc parseNodeStatsOptions
        "Print Node statistics.")))

debug :: [NodeId] -> DebugOptions -> Process ()
debug nids dbgo = case dbgo of
  EQStats x -> eqStats nids x
  RCStats x -> rcStats nids x
  CEPStats x -> cepStats nids x
  NodStats x -> nodeStats nids x

data EQStatsOptions = EQStatsOptions Int -- ^ Timeout for querying EQ.
                                     Bool -- ^ Request cep stats.
                                     Bool -- ^ Request memory stats.
  deriving (Eq, Show)

-- | Print Event Queue statistics.
eqStats :: [NodeId] -> EQStatsOptions -> Process ()
eqStats nids (EQStatsOptions t c m) = do
    self <- getSelfPid
    eqs <- findEQFromNodes t nids
    for_ eqs $ \eq -> do
      requestEQStats eq
      expect >>= liftIO . display
      when c $ do
        runtimeInfoRequest eq
        expect >>= displayCepReply
  where
    display (EQStatResp{..}) = do
      putStrLn $ printf "EQ size: %d" eqs_queue_size
      putStrLn $ printf "Worker pool max threads: %d" $ poolProcessBound eqs_pool_stats
      putStrLn $ printf "Worker pool current threads: %d" $ poolProcessCount eqs_pool_stats
      putStrLn $ printf "Worker pool tasks: %d" $ poolTaskCount eqs_pool_stats
      putStrLn "Message IDs in queue:"
      for_ eqs_uuids $ \uuid ->
        putStrLn $ "\t" ++ show uuid
    display EQStatRespCannotBeFetched = do
      hPutStrLn stderr "Cannot fetch EQ stats."
      exitFailure

parseEQStatsOptions :: O.Parser EQStatsOptions
parseEQStatsOptions = EQStatsOptions
  <$> O.option O.auto (
        O.metavar "TIMEOUT (μs)"
        <> O.long "eqt-timeout"
        <> O.value 1000000
        <> O.help ("Time to wait from a reply from the EQT when" ++
                  " querying the location of an EQ.")
      )
  <*> O.switch
        ( O.long "cep"
        <> O.short 'c'
        <> O.help "Show cep stats."
        )
  <*> O.switch
        ( O.long "memory"
       <> O.short 'm'
       <> O.help "Show memory allocation; this operation may be slow. Require -c"
        )

data RCStatsOptions = RCStatsOptions
    Int -- ^ Timeout for querying EQ
  deriving (Eq, Show)

-- | Print RC statistics
rcStats :: [NodeId] -> RCStatsOptions -> Process ()
rcStats nids (RCStatsOptions t) = do
    self <- getSelfPid
    eqs <- findEQFromNodes t nids
    _ <- promulgateEQ eqs $ DebugRequest self
    expect >>= liftIO . display
  where
    display (DebugResponse{..}) = do
      putStrLn $ printf "EQ nodes: %s" (show dr_eq_nodes)
      putStrLn $ printf (unlines
                          [ "Resource Graph:"
                          , "\t Elements: %d"
                          , "\t Deletions since GC: %d"
                          , "\t GC threshold: %d"
                          ]
                        )
                        dr_rg_elts dr_rg_since_gc dr_rg_gc_threshold
      putStrLn "Referenced messages:"
      for_ (M.toAscList dr_refCounts) $ \(uuid, cnt) ->
        putStrLn $ printf "\t%s | %d" (show uuid) cnt

parseRCStatsOptions :: O.Parser RCStatsOptions
parseRCStatsOptions = RCStatsOptions
  <$> O.option O.auto (
        O.metavar "TIMEOUT (μs)"
        <> O.long "eqt-timeout"
        <> O.value 1000000
        <> O.help ("Time to wait from a reply from the EQT when" ++
                  " querying the location of an EQ.")
      )

data CEPStatsOptions = CEPStatsOptions
    Int -- ^ Timeout for querying RC
    Bool -- ^ Show memory profiling
  deriving (Eq, Show)

-- | Print CEP statistics.
cepStats :: [NodeId] -> CEPStatsOptions -> Process ()
cepStats nids (CEPStatsOptions t m) = do
    self <- getSelfPid
    for_ nids $ \nid -> whereisRemoteAsync nid labelRecoveryCoordinator
    void . spawnLocal $ receiveTimeout t [] >> usend self ()
    fix $ \loop -> do
      void $ receiveWait
        [ matchIf (\(WhereIsReply s _) -> s == labelRecoveryCoordinator)
           $ \(WhereIsReply _ mp) ->
             if isNothing mp
             then loop
             else for_ mp $ \p -> do
               usend p (RuntimeInfoRequest self m)
               expect >>= displayCepReply
        , match $ \() -> liftIO $ do
            hPutStrLn stderr "RuntimeInfo cannot be fetched."
            exitFailure
        ]
  where
    labelRecoveryCoordinator = "mero-halon.RC"

displayCepReply :: RuntimeInfo -> Process ()
displayCepReply (RuntimeInfo{..}) = liftIO $ do
  putStrLn $ printf (unlines
                      [ "Total SMs: %d"
                      , "Running SMs: %d"
                      , "Suspended SMs : %d"
                      ]
                     )
                     infoTotalSM infoRunningSM infoSuspendedSM
  for_ infoMemory $ \MemoryInfo{..} ->
    putStrLn $ printf (unlines
                        [ "Total Memory: %dB"
                        , "SM size: %dB"
                        , "State size: %dB"
                        ]
                      )
                      minfoTotalSize minfoSMSize minfoStateSize
  displayRunningSMs infoSMs
  where
    displayRunningSMs sms = let
        heading = ("Rule name", "Running SMs")
        maxRuleNameLength :: Int
        maxRuleNameLength = maximum $ (length :: String -> Int) <$> M.keys sms
        padding = 3
        space n = replicate n ' '
      in do
        putStrLn (fst heading
                ++ (space (maxRuleNameLength - length (fst heading) + padding))
                ++ "|"
                ++ space padding
                ++ (snd heading)
                 )
        putStrLn $ replicate ( maxRuleNameLength
                             + 3*padding
                             + length (snd heading)
                             )
                             '-'
        for_ (M.toAscList sms) $ \(n, c) ->
          putStrLn $ n
                  ++ (space (maxRuleNameLength - length n + padding))
                  ++ "|"
                  ++ (space padding)
                  ++ (show c)


parseCEPStatsOptions :: O.Parser CEPStatsOptions
parseCEPStatsOptions = CEPStatsOptions
  <$> O.option O.auto (
        O.metavar "TIMEOUT (μs)"
        <> O.long "rc-timeout"
        <> O.value 1000000
        <> O.help ("Time to wait for the location of an RC on the given nodes.")
      )
  <*> O.switch
        ( O.long "memory"
       <> O.short 'm'
       <> O.help "Show memory allocation; this operation may be slow."
        )

data NodeStatsOptions = NodeStatsOptions
    Int -- ^ Timeout for querying EQ
  deriving (Eq, Show)

nodeStats :: [NodeId] -> NodeStatsOptions -> Process ()
nodeStats nids (NodeStatsOptions _) = do
    for_ nids $ \nid -> do
      liftIO $ putStrLn $ "Node: " ++ show nid
      getNodeStats nid >>= display
  where
    display :: Either DiedReason NodeStats -> Process ()
    display (Right NodeStats{..}) = liftIO $ do
      putStrLn $ printf (unlines
                          [ "Registered names: %d"
                          , "Monitors: %d"
                          , "Links: %d"
                          , "Processes: %d"
                          ]
                         )
                         nodeStatsRegisteredNames
                         nodeStatsMonitors
                         nodeStatsLinks
                         nodeStatsProcesses
    display (Left r) = liftIO $ do
      hPutStrLn stderr $ "Died: " ++ show r
      exitFailure

parseNodeStatsOptions :: O.Parser NodeStatsOptions
parseNodeStatsOptions = NodeStatsOptions
  <$> O.option O.auto (
        O.metavar "TIMEOUT (μs)"
        <> O.long "rc-timeout"
        <> O.value 1000000
        <> O.help ("Time to wait for the location of an RC on the given nodes.")
      )
