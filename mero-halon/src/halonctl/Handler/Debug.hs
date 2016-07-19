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

import HA.EventQueue (eventQueueLabel)
import HA.EventQueue.Producer (promulgateEQ)
import HA.EventQueue.Types
  ( EQStatResp(..)
  , EQStatReq(..)
  )
import HA.RecoveryCoordinator.Events.Debug
import Network.CEP (RuntimeInfoRequest(..), RuntimeInfo(..), MemoryInfo(..))

import Lookup

import Control.Applicative ((<|>))
import Control.Distributed.Process
import Control.Monad (void)
import Control.Monad.Fix (fix)

import Data.Foldable (for_)
import qualified Data.Map as M
import Data.Maybe (isNothing)
import Data.Monoid ((<>))

import qualified Options.Applicative as O
import qualified Options.Applicative.Extras as O

import Text.Printf (printf)

data DebugOptions =
    EQStats EQStatsOptions
  | RCStats RCStatsOptions
  | CEPStats CEPStatsOptions
  deriving (Eq, Show)

parseDebug :: O.Parser DebugOptions
parseDebug =
      ( EQStats <$> O.subparser ( O.command "eq" (O.withDesc parseEQStatsOptions
        "Print EQ statistics." )))
  <|> ( RCStats <$> O.subparser ( O.command "rc" (O.withDesc parseRCStatsOptions
        "Print RC statistics." )))
  <|> ( CEPStats <$> O.subparser ( O.command "cep" (O.withDesc parseCEPStatsOptions
        "Print CEP statistics." )))

debug :: [NodeId] -> DebugOptions -> Process ()
debug nids dbgo = case dbgo of
  EQStats x -> eqStats nids x
  RCStats x -> rcStats nids x
  CEPStats x -> cepStats nids x

data EQStatsOptions = EQStatsOptions Int -- ^ Timeout for querying EQ
  deriving (Eq, Show)

-- | Print Event Queue statistics.
eqStats :: [NodeId] -> EQStatsOptions -> Process ()
eqStats nids (EQStatsOptions t) = do
    self <- getSelfPid
    eqs <- findEQFromNodes t nids
    for_ eqs $ \eq -> do
      nsendRemote eq eventQueueLabel $ EQStatReq self
    expect >>= liftIO . display
  where
    display (EQStatResp queueSize uuids) = do
      putStrLn $ printf "EQ size: %d" queueSize
      putStrLn "Message IDs in queue:"
      for_ uuids $ \uuid ->
        putStrLn $ "\t" ++ show uuid
    display EQStatRespCannotBeFetched =
      putStrLn "Cannot fetch EQ stats."

parseEQStatsOptions :: O.Parser EQStatsOptions
parseEQStatsOptions = EQStatsOptions
  <$> O.option O.auto (
        O.metavar "TIMEOUT (μs)"
        <> O.long "eqt-timeout"
        <> O.value 1000000
        <> O.help ("Time to wait from a reply from the EQT when" ++
                  " querying the location of an EQ.")
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
               expect >>= display
        , match $ \() -> liftIO $ putStrLn "RuntimeInfo cannot be fetched."
        ]
  where
    display :: RuntimeInfo -> Process ()
    display (RuntimeInfo{..}) = liftIO $ do
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
    labelRecoveryCoordinator = "mero-halon.RC"


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
