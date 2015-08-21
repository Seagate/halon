{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.StackDriver where

import Control.Distributed.Process
import Data.Foldable (foldlM)
import Data.Monoid ((<>))

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.Stack
import Network.CEP.Types

data PushInput g = PushInput Subscribers g Input

newtype StackDriver g =
    StackDriver (PushInput g -> Process (g,[(StackOut g, StackDriver g)]))

runStackDriver :: Subscribers
               -> g
               -> Input
               -> StackDriver g
               -> Process (g, [(StackOut g, StackDriver g)])
runStackDriver subs g i (StackDriver k) = k (PushInput subs g i)

oneOffDriver :: Phase g l -> StackSM g l -> StackDriver g
oneOffDriver sp init_sm = StackDriver $ boot init_sm
  where
    boot sm i = cruise (runStackSM (StackPush sp) sm) i
    cruise sm (PushInput subs g i) =
      fmap (map next) <$> runStackSM (StackIn subs g i) sm
    next = fmap (StackDriver . cruise)

permanentDriver :: forall g l . Phase g l -> StackSM g l -> StackDriver g
permanentDriver sp init_sm = StackDriver $ boot init_sm
  where
    boot sm i = cruise (runStackSM (StackPush sp) sm) i

    cruise sm (PushInput subs g i) = do
      (g', machines) <- runStackSM (StackIn subs g i) sm
      let next :: (g, [(StackOut g, StackDriver g)]) -> (StackOut g, StackSM g l) -> Process (g, [(StackOut g, StackDriver g)])
          next (gNext,acc) (out,nxt_sm) = do
            let StackOut nxt_g rep res lgs b = out
            case res of
              EmptyStack | b ->
                  let greedy :: [ExecutionReport] -> g -> StackSM g l -> [Logs] -> Process (g,[(StackOut g, StackDriver g)])
                      greedy reps cur_g cur_sm lgsGreedy =
                        let input = StackIn subs cur_g NoMessage
                            toDriver :: g -> [(StackOut g, StackSM g l)] -> Process (g, [(StackOut g,StackDriver g)])
                            toDriver gD [] = return (gD, [])
                            toDriver gD ((c_out,n_sm):xs) =
                              let StackOut n_g c_r c_re logs b' = c_out in
                              case c_re of
                                EmptyStack
                                  | hasNonEmptyBuffers $ exeInfos c_r ->
                                    let int_sm' = runStackSM (StackPush sp) n_sm
                                    in do (gD', xs') <- greedy (c_r:reps) n_g int_sm' (lgsGreedy <> logs)
                                          (gD'',ys') <- toDriver gD' xs
                                          return (gD'', xs' ++ ys')
                                  | otherwise -> do
                                      let f_r  = mergeReports (c_r:reps)
                                          f_sm = runStackSM (StackPush sp) n_sm
                                          f_o  = StackOut n_g f_r c_re (lgsGreedy <> logs) b'
                                      (gD', ys) <- toDriver gD xs
                                      return (gD', (f_o, StackDriver $ cruise f_sm):ys)
                                NeedMore -> do
                                  let f_r  = mergeReports (c_r:reps)
                                      f_sm = runStackSM (StackPush sp) n_sm
                                      f_o  = StackOut n_g f_r c_re (lgsGreedy <> logs) b'
                                  (gD', ys) <- toDriver gD xs
                                  return (gD', (f_o, StackDriver $ cruise f_sm):ys)
                        in uncurry toDriver =<< runStackSM input cur_sm
                      int_sm = runStackSM (StackPush sp) nxt_sm
                  in fmap (++acc) <$> greedy [rep] nxt_g int_sm lgs
              _ -> return (gNext, (out, StackDriver (cruise nxt_sm)):acc)
      foldlM next (g',[]) machines

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
