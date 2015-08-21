{-# LANGUAGE GADTs               #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- |
-- Copyright: (C) 2015 Tweag I/O Limited
--
module Network.CEP.Stack where

import Data.Traversable (for, forM)
import Data.Foldable (foldlM, toList)
import Data.Typeable

import           Control.Distributed.Process
import Data.Monoid ((<>))
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
    { _soGlobal    :: !g                    -- ^ Current global state.
    , _soExeReport :: !ExecutionReport      -- ^ Execution report.
    , _soResult    :: !StackResult          -- ^ Result of running a stack.
    , _soLogs      :: [Logs]                -- ^ Logs.
    , _soStopped   :: !Bool                 -- ^ Flag that shows if SM should be removed from the queue.
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
                (Maybe SMLogs)
    | StackSuspend Buffer (StackCtx g l) (Maybe SMLogs) Bool

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
          NoMessage -> executeStack subs sm g 0 0 [] [] xs [] False
          GotMessage (TypeInfo _ (_ :: Proxy e)) msg -> do
            Just (a :: e) <- unwrapMessage msg
            let input = PushMsg a
            broadcast subs input xs sm g

    broadcast :: Subscribers -> SM_In g l (SM g l) -> [StackSlot g l] -> SM g l -> g -> Process (g,[(StackOut g, StackSM g l)])
    broadcast subs i xs sm g =
        let nxt_sm = unSM sm g i
        in executeStack subs nxt_sm g 0 0 [] [] xs [] False

{-
        let next (nextG,acc) (_, _, SM_Unit Nothing, nxt_sm) = do
              xs' <- for xs $ \slot ->
                case slot of
                  OnMainSM _       -> return slot
                  OnChildSM _ _ -> error "OnChildSM"
              fmap (acc++) <$>
        foldlM next (broadcastG,[]) machines
        -}

    executeStack :: Subscribers
                 -> SM g l
                 -> g
                 -> Int -- Spawn SMs
                 -> Int -- Terminated SMs
                 -> [ExecutionInfo]
                 -> [StackSlot g l]
                 -> [StackSlot g l]
                 -> [Logs]
                 -> Bool
                 -> Process (g, [(StackOut g, StackSM g l)])
    executeStack _ sm g ssms tsms rp done [] executeLogs stopped =
        let res = if null done then EmptyStack else NeedMore
            eis = reverse rp
            rep = ExecutionReport ssms tsms eis in
        return (g, [(StackOut g rep res executeLogs stopped, StackSM $ go (reverse done) sm)])
    executeStack subs sm gStack ssms tsms rp done (x:xs) executeLogs stopped =
        case x of
          OnMainSM ctx -> do
            (gStack', stacks') <- contextStack subs sm gStack ctx
            let next (gNext,acc) res = do
                  case res of
                    StackDone pph p_buf buf pinfo _ phs nxt_sm lgs -> do
                      phsm <- createSlots OnMainSM pph phs
                      let jobs = phsm
                          n_ssms = ssms                      -- XXX: not counted
                          r = SuccessExe pinfo p_buf buf
                          lgs' = maybe executeLogs
                                 (\ls -> Logs name (toList ls):executeLogs) lgs
                      fmap (acc++) <$> executeStack subs nxt_sm gNext n_ssms
                                                    tsms (r:rp) done (xs ++ jobs) lgs' True
                    StackSuspend buf new_ctx lgs b -> do
                      let slot = OnMainSM new_ctx
                          r    = FailExe (infoTarget ctx) SuspendExe buf
                          lgs' = maybe executeLogs
                                 (\ls -> Logs name (toList ls):executeLogs) lgs
                      fmap (acc++) <$> executeStack subs sm gNext ssms
                                                    tsms (r:rp) (slot:done) xs lgs' (stopped || b)
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
            SM_Complete _ _ss hs lgs -> do
              phs <- phases hs
              return $ StackDone ph p_buf buf pinfo gStack' phs next_sm lgs
            SM_Suspend lgs -> return $ StackSuspend buf ctx lgs True
            SM_Stop    lgs -> return $ StackSuspend buf ctx lgs False
            SM_Unit    _   -> error "impossible happened"
        return (gStack', machines')
    contextStack subs sm gStack (StackSwitch ph xs) =
        let loop gLoop buf done [] lgs b = return (gLoop
                                              , [StackSuspend buf
                                                 (StackSwitch ph (reverse done)) lgs b])
            loop gLoop _ done (a:as) lgs _ = do
              let input = Execute subs a
              (gLoop', machines) <- unSM sm gLoop input
              let next :: (g,[StackCtxResult g l])
                       -> (Buffer, Buffer, SM_Out g l, SM g l)
                       -> Process (g,[StackCtxResult g l])
                  next (gNext,accum) (p_buf, buf, out, nxt_sm) =
                    case out of
                      SM_Complete _ _ss hs lgs' -> do
                        phs <- phases hs
                        let pname = _phName a
                            pas   = fmap _phName $ reverse done
                            pinfo = StackSwitchPhase (_phName ph) pname pas
                        return (gNext, StackDone a p_buf buf pinfo gNext phs nxt_sm (lgs'<>lgs):accum)
                      SM_Suspend lgs' -> do
                        (gNext',result) <- loop gNext buf (a:done) as (lgs'<>lgs) True
                        return (gNext', result ++ accum)
                      SM_Stop  lgs'  -> loop gNext buf done as (lgs' <> lgs) True
                      SM_Unit  _     -> error "impossible happened"
              fmap reverse <$> foldlM next (gLoop',[]) machines
        in loop gStack emptyFifoBuffer [] xs Nothing False

    phases hs = for hs $ \h ->
        case M.lookup (_phHandle h) ps of
          Just ph -> return ph
          Nothing -> fail $ "impossible: rule " ++ name
                          ++ " doesn't have a phase named " ++ _phHandle h

    createSlots :: (StackCtx g l -> StackSlot g l)
                -> Phase g l
                -> [Phase g l]
                -> Process [StackSlot g l]
    createSlots mk p phs =
        case phs of
          []  -> return []
          [x] -> return [mk $ StackNormal x]
          xs  -> return [mk $ StackSwitch p xs]
