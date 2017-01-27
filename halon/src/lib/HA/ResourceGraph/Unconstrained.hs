module HA.ResourceGraph.Unconstrained where

import HA.ResourceGraph (Resource, Relation)
import qualified HA.ResourceGraph.GraphLike as GL

type family Unconstrained (a :: *) :: Constraint where
  Unconstrained a = ()

data Res = forall a. (Static a, ByteString)
data Rel = forall a. (Static a, Word8, ByteString, ByteString, ByteString)

data UGraph = Graph
  { -- | Channel used to communicate with the multimap which replicates the
    -- graph.
    _grMMChan :: StoreChan
    -- | Changes in the graph with respect to the version stored in the multimap.
  , _grChangeLog :: !ChangeLog
    -- | The graph.
  , _grGraph :: HashMap Res (HashSet Rel)
  } deriving (Typeable)
makeLenses ''UGraph

instance GL.GraphLike UGraph where
  type GL.InsertableRes UGraph = Resource
  type GL.InsertableRel UGraph = Relation

  type GL.Resource UGraph = SafeCopy
  type GL.Relation UGraph r a b = SafeCopy r

  type GL.UniversalResource UGraph = Res
  type GL.UniversalRelation UGraph = Rel

  encodeUniversalResource (x, y) = toStrict $ encode x `append` y
  
  encodeIRes r = ( $(mkStatic 'someResourceDict) `staticApply`
                     (resourceDict :: Static (Dict (Resource r)))
                  , safePut r)

  queryRes r = (\x -> snd x == safePut r)

  graph = grGraph

  changelog = grChangeLog

  storeChan = grMMChan
