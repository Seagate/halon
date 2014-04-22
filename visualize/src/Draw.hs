{-# LANGUAGE RecordWildCards #-}
module Draw where

import Graphics.Gloss
import Graphics.Gloss.Interface.IO.Animate

import Data.Maybe (fromJust)
import System.Environment
import qualified Tree
import Control.Monad.State
import Control.Concurrent.Chan
import Data.IORef


nodeRadius = 5.0

nodeVSep = 100.0

canvasSize :: (Int, Int)
canvasSize = (800, 300)

canvasWidth, canvasHeight :: Float
canvasWidth = fromIntegral $ fst canvasSize
canvasHeight = fromIntegral $ snd canvasSize

hfillForestChildren :: Float -> [Tree.Tree a] -> [Tree.Tree a]
hfillForestChildren w ts = evalState (mapM placeTree ts) 1
    where n = sum $ map (length . Tree.members) ts
          sep = w / fromIntegral (n + 1) 
          placeTree Tree.Tree{..} = do
            members' <- mapM placeMember members
            return Tree.Tree{members=members',..}
          placeMember Tree.Tree{..} = do
            i <- get
            put (i + 1)
            return $ Tree.Tree{position=fromIntegral i * sep,..}

-- Recursively draw all children of the given tree.
drawForest :: Tree.Forest a -> Picture
drawForest ts = pictures $ loop 0 [] (Tree.members $ head $ hfillForestChildren canvasWidth $ return $ Tree.merge undefined $ ts)
    where loop d [] [] = []
          loop d [] outs = loop (d + 1) (hfillForestChildren canvasWidth outs) []
          loop d (Tree.Tree{position=x,..}:ins) outs =
              let y = nodeVSep * fromIntegral d
              in translate x y node :
                 map ((\ x' -> edge (x, y) (x', y + nodeVSep)) . Tree.position) members ++
                 loop d ins (members ++ outs)
          edge from to = Line [from, to]
          node = circle nodeRadius

data Message = LeaderElected Tree.Level Int Int

updateForest :: Message -> Tree.Forest Int -> Tree.Forest Int
updateForest (LeaderElected lvl ldr mbr) ts
    -- Electing a leader at level 0 means node creation.
    | lvl == 0 = Tree.singleton ldr : ts
    | otherwise = uncurry (Tree.graft lvl ldr) $ fmap fromJust $ Tree.cut (lvl - 1) mbr $ ts

doAnimation :: Chan Message -> IO ()
doAnimation incoming = do
  ref <- newIORef []
  animateIO (InWindow "HA Nodes" canvasSize (10, 10)) white $ const $ do
                ts <- readIORef ref
                let processPendingMessages ts = do
                         b <- isEmptyChan incoming
                         if b then return ts
                         else do msg <- readChan incoming
                                 processPendingMessages $ updateForest msg ts
                ts' <- processPendingMessages ts
                writeIORef ref ts'
                return $ translate (canvasWidth / (-2)) (canvasHeight / (-2) + 20) $ drawForest $ ts'

test :: IO ()
test = do
  [numNodes] <- getArgs
  animate (InWindow "Test" canvasSize (10, 10)) white $ const $ translate (canvasWidth / (-2)) (canvasHeight / (-2) + 20) $ drawForest $ t1 (read numNodes)

t1 :: (Enum a, Num a) => a -> [Tree.Tree a]
t1 n = [Tree.merge 0 $ map Tree.singleton [1..n]]