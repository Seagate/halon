{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.Stack where

import Data.Traversable (for)
import Data.Typeable

import           Control.Distributed.Process
import qualified Data.Map.Strict as M

import Network.CEP.Buffer
import Network.CEP.Execution
import Network.CEP.SM
import Network.CEP.Types

data Input
    = NoMessage
    | GotMessage TypeInfo Message

data StackIn g l a where
    StackIn :: Subscribers
            -> g
            -> Input
            -> StackIn g l (Process (StackOut g, StackSM g l))

    StackPush :: Phase g l -> StackIn g l (StackSM g l)

data StackOut g =
    StackOut
    { _soGlobal    :: !g
    , _soExeReport :: !ExecutionReport
    , _soResult    :: !StackResult
    }

newtype StackSM g l = StackSM (forall a. StackIn g l a -> a)

runStackSM :: StackIn g l a -> StackSM g l -> a
runStackSM i (StackSM k) = k i

data StackCtx g l
    = StackNormal (Phase g l)
    | StackSwitch (Phase g l) [Phase g l]

data StackCtxResult g l
    = StackDone (Phase g l)
                Buffer
                Buffer
                StackPhaseInfo
                g
                [SpawnSM g l]
                [Phase g l]
                (SM g l)
    | StackSuspend Buffer (StackCtx g l)

data StackSlot g l
    = OnMainSM (StackCtx g l)
    | OnChildSM (SM g l) (StackCtx g l)

infoTarget :: StackCtx g l -> String
infoTarget (StackNormal ph)   = _phName ph
infoTarget (StackSwitch p xs) = show (fmap _phName xs)
                              ++ " from |" ++ _phName p ++ "| (switch)"

newStackSM :: String
           -> Maybe SMLogs
           -> M.Map String (Phase g l)
           -> Buffer
           -> l
           -> StackSM g l
newStackSM rn logs ps buf l =
    StackSM (mainStackSM rn logs ps buf l)

mainStackSM :: forall a g l. String      -- Rule name.
            -> Maybe SMLogs             -- If we collect logs.
            -> M.Map String (Phase g l) -- Rule phases.
            -> Buffer                   -- Init buffer (when forking new SM).
            -> l                        -- Local state.
            -> StackIn g l a
            -> a
mainStackSM name logs ps init_buf sl = go [] (newSM init_buf logs sl)
  where
    go :: forall b. [StackSlot g l] -> SM g l -> StackIn g l b -> b
    go xs sm (StackPush ph) =
        let x = OnMainSM (StackNormal ph) in
        StackSM $ go (x:xs) sm
    go xs sm (StackIn subs g i) =
        case i of
          NoMessage -> executeStack subs sm g 0 0 [] [] xs
          GotMessage (TypeInfo _ (_ :: Proxy e)) msg -> do
            Just (a :: e) <- unwrapMessage msg
            let input = PushMsg a
            broadcast subs input xs sm g

    broadcast :: Subscribers -> SM_In g l () -> [StackSlot g l] -> SM g l -> g -> Process (StackOut g, StackSM g l)
    broadcast subs i xs sm g = do
        (_, _, SM_Unit, nxt_sm) <- unSM sm i
        xs' <- for xs $ \slot ->
          case slot of
            OnMainSM _       -> return slot
            OnChildSM lsm ph -> do
              (_, _, SM_Unit, nxt_lsm) <- unSM lsm i
              return $ OnChildSM nxt_lsm ph

        executeStack subs nxt_sm g 0 0 [] [] xs'

    executeStack :: Subscribers
                 -> SM g l
                 -> g
                 -> Int -- Spawn SMs
                 -> Int -- Terminated SMs
                 -> [ExecutionInfo]
                 -> [StackSlot g l]
                 -> [StackSlot g l]
                 -> Process (StackOut g, StackSM g l)
    executeStack _ sm g ssms tsms rp done [] =
        let res = if null done then EmptyStack else NeedMore
            eis = reverse rp
            rep = ExecutionReport ssms tsms eis in
        return (StackOut g rep res, StackSM $ go (reverse done) sm)
    executeStack subs sm g ssms tsms rp done (x:xs) =
        case x of
          OnMainSM ctx -> do
            res <- contextStack subs sm g ctx
            case res of
              StackDone pph p_buf buf pinfo g' ss phs nxt_sm -> do
                phsm <- createSlots OnMainSM pph phs
                let ssm    = spawnSMs ss
                    jobs   = phsm ++ ssm
                    n_ssms = ssms + length ssm
                    r      = SuccessExe pinfo p_buf buf
                executeStack subs nxt_sm g' n_ssms tsms (r:rp) done
                                                                  (xs ++ jobs)
              StackSuspend buf new_ctx ->
                let slot = OnMainSM new_ctx
                    r    = FailExe (infoTarget ctx) SuspendExe buf  in
                executeStack subs sm g ssms tsms (r:rp) (slot:done) xs
          OnChildSM lsm ctx -> do
            res <- contextStack subs lsm g ctx
            case res of
              StackDone pph p_buf buf pinfo g' ss phs nxt_lsm -> do
                phsm <- createSlots (OnChildSM nxt_lsm) pph phs
                let ssm    = spawnSMs ss
                    n_tsms = if null phs then tsms + 1 else tsms
                    n_ssms = length ssm + ssms
                    jobs   = phsm ++ ssm
                    r      = SuccessExe pinfo p_buf buf
                executeStack subs sm g' n_ssms n_tsms (r:rp) done (xs ++ jobs)
              StackSuspend buf new_ctx ->
                let slot = OnChildSM lsm new_ctx
                    r    = FailExe (infoTarget ctx) SuspendExe buf in
                executeStack subs sm g ssms tsms (r:rp) (slot:done) xs

    contextStack :: Subscribers
                 -> SM g l
                 -> g
                 -> StackCtx g l
                 -> Process (StackCtxResult g l)
    contextStack subs sm g ctx@(StackNormal ph) = do
        (p_buf, buf, out, nxt_sm) <- unSM sm (Execute subs g ph)
        let pinfo = StackSinglePhase $ _phName ph
        case out of
          SM_Complete g' _ ss hs -> do
            phs <- phases hs
            return $ StackDone ph p_buf buf pinfo g' ss phs nxt_sm
          SM_Suspend -> return $ StackSuspend buf ctx
          SM_Stop    -> return $ StackDone ph buf buf pinfo g [] [] sm
    contextStack subs sm g (StackSwitch ph xs) =
        let loop buf done []   = return $ StackSuspend buf
                                        $ StackSwitch ph (reverse done)
            loop _ done (a:as) = do
              let input = Execute subs g a
              (p_buf, buf, out, nxt_sm) <- unSM sm input
              case out of
                SM_Complete g' _ ss hs -> do
                  phs <- phases hs
                  let pname = _phName a
                      pas   = fmap _phName $ reverse done
                      pinfo = StackSwitchPhase (_phName ph) pname pas
                  return $ StackDone a p_buf buf pinfo g' ss phs nxt_sm
                SM_Suspend -> loop buf (a:done) as
                SM_Stop    -> loop buf done as
        in loop emptyFifoBuffer [] xs

    phases hs = for hs $ \h ->
        case M.lookup (_phHandle h) ps of
          Just ph -> return ph
          Nothing -> fail $ "impossible: rule " ++ name
                          ++ " doesn't have a phase named " ++ _phHandle h

    spawnSMs xs =
        let spawnIt (SpawnSM tpe l action) =
              let tmp_buf =
                    case tpe of
                      CopyThatBuffer buf -> buf
                      CreateNewBuffer    -> init_buf
                  fsm = newSM tmp_buf logs l
                  phc  = DirectCall action
                  ctx  = StackNormal $ Phase (name ++ "-child") phc in
              OnChildSM fsm ctx in
        fmap spawnIt xs

    createSlots :: (StackCtx g l -> StackSlot g l)
                -> Phase g l
                -> [Phase g l]
                -> Process [StackSlot g l]
    createSlots mk p phs =
        case phs of
          []  -> return []
          [x] -> return [mk $ StackNormal x]
          xs  -> return [mk $ StackSwitch p xs]