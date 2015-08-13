{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.Stack where

import Data.Traversable (for, forM)
import Data.Foldable (foldlM)
import Data.Typeable
-- import Data.List (partition)

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
            -> StackIn g l (Process (g, [(StackOut g, StackSM g l)]))

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

mainStackSM :: forall a g l. String     -- Rule name.
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

    broadcast :: Subscribers -> SM_In g l () -> [StackSlot g l] -> SM g l -> g -> Process (g,[(StackOut g, StackSM g l)])
    broadcast subs i xs sm g = do
        (broadcastG, machines) <- unSM sm g i
        let next (nextG,acc) (_, _, SM_Unit, nxt_sm) = do
              xs' <- for xs $ \slot ->
                case slot of
                  OnMainSM _       -> return slot
                  OnChildSM _ _ -> error "OnChildSM"
                  {-
                  OnChildSM lsm ph -> do
                    (_, _, SM_Unit, nxt_lsm) <- unSM lsm i
                    return $ OnChildSM nxt_lsm ph
                    -}
              fmap (acc++) <$> executeStack subs nxt_sm nextG 0 0 [] [] xs'
        foldlM next (broadcastG,[]) machines

    executeStack :: Subscribers
                 -> SM g l
                 -> g
                 -> Int -- Spawn SMs
                 -> Int -- Terminated SMs
                 -> [ExecutionInfo]
                 -> [StackSlot g l]
                 -> [StackSlot g l]
                 -> Process (g, [(StackOut g, StackSM g l)])
    executeStack _ sm g ssms tsms rp done [] =
        let res = if null done then EmptyStack else NeedMore
            eis = reverse rp
            rep = ExecutionReport ssms tsms eis in
        return (g, [(StackOut g rep res, StackSM $ go (reverse done) sm)])
    executeStack subs sm gStack ssms tsms rp done (x:xs) =
        case x of
          OnMainSM ctx -> do
            (gStack', stacks') <- contextStack subs sm gStack ctx
            let next (gNext,acc) res = do
                  case res of
                    StackDone pph p_buf buf pinfo _ phs nxt_sm -> do
                      phsm <- createSlots OnMainSM pph phs
                      let jobs = phsm
                          n_ssms = ssms                      -- XXX: not counted
                          r = SuccessExe pinfo p_buf buf
                      fmap (acc++) <$> executeStack subs nxt_sm gNext n_ssms
                                                    tsms (r:rp) done (xs ++ jobs)
                    StackSuspend buf new_ctx -> do
                      let slot = OnMainSM new_ctx
                          r    = FailExe (infoTarget ctx) SuspendExe buf
                      fmap (acc++) <$> executeStack subs sm gNext ssms
                                                    tsms (r:rp) (slot:done) xs
            foldlM next (gStack',[]) stacks'
          OnChildSM _ _ -> error "OnChildSM is no longer supported"

    contextStack :: Subscribers
                 -> SM g l
                 -> g
                 -> StackCtx g l
                 -> Process (g,[StackCtxResult g l])
    contextStack subs sm gStack ctx@(StackNormal ph) = do
        let pinfo = StackSinglePhase $ _phName ph
        (gStack', machines) <- unSM sm gStack (Execute subs ph)
        machines' <- forM machines $ \(p_buf, buf, out, next_sm) ->
          case out of
            SM_Complete _ _ss hs -> do
              phs <- phases hs
              return $ StackDone ph p_buf buf pinfo gStack' phs next_sm
            SM_Suspend -> return $ StackSuspend buf ctx
            SM_Stop    -> return $ StackDone ph buf buf pinfo gStack' [] sm
        return (gStack', machines')
    contextStack subs sm gStack (StackSwitch ph xs) =
        let loop gLoop buf done []   = return (gLoop
                                              , [StackSuspend buf
                                                $ StackSwitch ph (reverse done)])
            loop gLoop _ done (a:as) = do
              let input = Execute subs a
              (gLoop', machines) <- unSM sm gLoop input
              let next :: (g,[StackCtxResult g l])
                       -> (Buffer, Buffer, SM_Out g l SM_Exe, SM g l)
                       -> Process (g,[StackCtxResult g l])
                  next (gNext,accum) (p_buf, buf, out, nxt_sm) =
                    case out of
                      SM_Complete _ _ss hs -> do
                        phs <- phases hs
                        let pname = _phName a
                            pas   = fmap _phName $ reverse done
                            pinfo = StackSwitchPhase (_phName ph) pname pas
                        return (gNext, StackDone a p_buf buf pinfo gNext phs nxt_sm:accum)
                      SM_Suspend -> do
                        (gNext',result) <- loop gNext buf (a:done) as
                        return (gNext', result ++ accum)
                      SM_Stop    -> loop gNext buf done as
              fmap reverse <$> foldlM next (gLoop',[]) machines
        in loop gStack emptyFifoBuffer [] xs

    phases hs = for hs $ \h ->
        case M.lookup (_phHandle h) ps of
          Just ph -> return ph
          Nothing -> fail $ "impossible: rule " ++ name
                          ++ " doesn't have a phase named " ++ _phHandle h

    {-
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
        -}

    createSlots :: (StackCtx g l -> StackSlot g l)
                -> Phase g l
                -> [Phase g l]
                -> Process [StackSlot g l]
    createSlots mk p phs =
        case phs of
          []  -> return []
          [x] -> return [mk $ StackNormal x]
          xs  -> return [mk $ StackSwitch p xs]
