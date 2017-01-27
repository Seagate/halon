module HA.ResourceGraph.GraphLike where

class GraphLike a where
  type InsertableRes a :: * -> Constraint
  type InsertableRel a :: * -> * -> * -> Constraint

  type Resource a :: * -> Constraint
  type Relation a :: * -> * -> * -> Constraint

  type UniversalResource a :: *
  type UniversalRelation a :: *

  encodeUniversalResource :: UniversalResource
                          -> ByteString
  encodeUniversalRelation :: UniversalRelation
                          -> ByteString
  decodeUniversalResource :: RemoteTable
                          -> ByteString
                          -> UniversalResource
  decodeUniversalRelation :: RemoteTable
                          -> ByteString
                          -> UniversalRelation

  encodeIRes :: InsertableRes a => a -> UniversalResource
  encodeIRelIn :: InsertableRel r a b => a -> r -> b -> UniversalRelation
  encodeIRelOut :: InsertableRel r a b => a -> r -> b -> UniversalRelation

  queryRes :: Resource a => a -> (UniversalResource -> Bool)
  queryRel :: Relation r a b -> a -> r -> b -> (UniversalRelation -> Bool)

  graph :: Lens' a (HashMap UniversalResource (HashSet UniversalRelation))

  storeChan :: Lens' a StoreChan

  changeLog :: Lens' a ChangeLog

memberResource :: (GraphLike g, Resource g a) => a -> g -> Bool
memberResource a g = isJust . find (queryRes a) $ M.keys $ g ^. graph

-- | Adds a relation without making a conversion from 'Edge'.
--
-- Unlike 'connect', it doesn't check cardinalities.
connectUnbounded :: ( GraphLike g
                    , InsertableRes g a
                    , InsertableRes g b
                    , InsertableRel g r a b
                    )
                 => a -> r -> b -> g -> g
connectUnbounded x r y g =
    over changeLog
      (updateChangeLog $
         InsertMany [ (eRes x),[ eRelO r x y ])
                    , (eRes y),[ eRelI r x y ])
                    ]
      )
    . over graph
        ( M.insertWith S.union (encodeIRes x) (S.singleton $ encodeIRelOut r x y)
        . M.insertWith S.union (encodeIRes y) (S.singleton $ encodeIRelIn r x y)
        )
    $ g
  where
    eRes = encodeUniversalResource . encodeIRes
    eRelI = encodeUniversalRelation . encodeIRelIn
    eRelO = encodeUniversalRelation . encodeIRelOut
