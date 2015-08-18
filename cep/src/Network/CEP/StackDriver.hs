{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.StackDriver where

import Control.Distributed.Process
import Data.Monoid ((<>))

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.Stack
import Network.CEP.Types

data PushInput g = PushInput Subscribers g Input

newtype StackDriver g =
    StackDriver (PushInput g -> Process (StackOut g, StackDriver g))

runStackDriver :: Subscribers
               -> g
               -> Input
               -> StackDriver g
               -> Process (StackOut g, StackDriver g)
runStackDriver subs g i (StackDriver k) = k (PushInput subs g i)

oneOffDriver :: Phase g l -> StackSM g l -> StackDriver g
oneOffDriver sp init_sm = StackDriver $ boot init_sm
  where
    boot sm i = cruise (runStackSM (StackPush sp) sm) i

    cruise sm (PushInput subs g i) = do
      (res, nxt_sm) <- runStackSM (StackIn subs g i) sm
      return (res, StackDriver $ cruise nxt_sm)

permanentDriver :: Phase g l -> StackSM g l -> StackDriver g
permanentDriver sp init_sm = StackDriver $ boot init_sm
  where
    boot sm i = cruise (runStackSM (StackPush sp) sm) i

    cruise sm (PushInput subs g i) = do
      (out, nxt_sm) <- runStackSM (StackIn subs g i) sm
      let StackOut nxt_g rep res lgs = out
      case res of
        EmptyStack ->
            let greedy reps cur_g cur_sm lgsGreedy = do
                  let input = StackIn subs cur_g NoMessage
                  (c_out, n_sm) <- runStackSM input cur_sm
                  let StackOut n_g c_r c_re logs = c_out
                  case c_re of
                    EmptyStack
                      | hasNonEmptyBuffers $ exeInfos c_r ->
                        let int_sm = runStackSM (StackPush sp) n_sm in
                        greedy (c_r:reps) n_g int_sm lgsGreedy
                      | otherwise -> do
                        let f_r  = mergeReports (c_r:reps)
                            f_sm = runStackSM (StackPush sp) n_sm
                            f_o  = StackOut n_g f_r c_re (lgsGreedy <> logs)
                        return (f_o, StackDriver $ cruise f_sm)
                    NeedMore ->
                      let f_r = mergeReports (c_r:reps)
                          f_o = StackOut n_g f_r c_re (lgsGreedy <> logs) in
                      return (f_o, StackDriver $ cruise n_sm) in
            let int_sm = runStackSM (StackPush sp) nxt_sm in
            greedy [rep] nxt_g int_sm lgs
        NeedMore -> return (out, StackDriver $ cruise nxt_sm)

hasNonEmptyBuffers :: [ExecutionInfo] -> Bool
hasNonEmptyBuffers [] = False
hasNonEmptyBuffers xs = any go xs
  where
    go (SuccessExe _ _ buf) = not $ bufferEmpty buf
    go _                    = False

mergeReports :: [ExecutionReport] -> ExecutionReport
mergeReports = foldl1 go . reverse
  where
    go a b =
      ExecutionReport
      { exeSpawnSMs = exeSpawnSMs a + exeSpawnSMs b
      , exeTermSMs  = exeTermSMs a + exeTermSMs b
      , exeInfos    = exeInfos a ++ exeInfos b
      }
