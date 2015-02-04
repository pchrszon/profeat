{-# LANGUAGE DeriveFunctor   #-}
{-# LANGUAGE LambdaCase      #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Builders for constructing 'Bdd's.
--
-- Internally, a Builder uses a Shared Ordered Binary Decision Diagram to
-- ensure all 'Bdd's are reduced and nodes are shared when possible.
module Data.Bdd.Builder
  ( -- * Builder Type
    BuilderT, Builder
  , runBuilderT, runBuilder
  , getSobdd
  , newVariable
    -- * BDD Builders
  , true, false
  , projection
  , not
  , and
  , or
  , implies
  , ite
  ) where

import Prelude hiding ( and, or, not )

import Control.Applicative
import Control.Lens
import Control.Monad.Identity
import Control.Monad.State.Strict

import Data.Map                   ( Map )
import qualified Data.Map as Map

import Data.Bdd.Internal

type UniqueTable = Map (Variable, Bdd, Bdd) Bdd

data BuilderState = BuilderState
  { _uniqueTable :: !UniqueTable
  , _lastNodeId  :: !NodeId
  , _varCount    :: !Int
  }

makeLenses ''BuilderState

initialState :: BuilderState
initialState = BuilderState
  { _uniqueTable = Map.empty
  , _lastNodeId  = 1 -- 0 and 1 reserved for terminal nodes
  , _varCount    = 0
  }

-- | A @BuilderT@ is used to construct 'Bdd's.
newtype BuilderT m a = B { unB :: StateT BuilderState m a } deriving (Functor)

instance (Functor m, Monad m) => Applicative (BuilderT m) where
    pure    = B . pure
    f <*> x = B $ unB f <*> unB x

instance Monad m => Monad (BuilderT m) where
    return = B . return
    m >>= f = B $ unB m >>= (unB . f)

instance MonadTrans BuilderT where
    lift = B . lift

-- | 'BuilderT' over 'Identity'.
type Builder a = BuilderT Identity a

-- | Run a 'BuilderT' computation.
runBuilderT :: Monad m => BuilderT m a -> m a
runBuilderT m = evalStateT (unB m) initialState

-- | Run a 'Builder' computation.
runBuilder :: Builder a -> a
runBuilder = runIdentity . runBuilderT

-- | Returns the internal SOBDD.
getSobdd :: Monad m => BuilderT m Sobdd
getSobdd = B $ do
    ns <- use $ uniqueTable.to Map.elems
    return . Sobdd $ false:true:ns

-- | Add a 'Bdd' node to the internal SOBDD. If an isomorphic node already
-- exists it is returned, instead of creating a new (redundant) node.
addNode :: Monad m => Variable -> Bdd -> Bdd -> BuilderT m Bdd
addNode var t e = B $ do
    let info = (var, t, e)
    use (uniqueTable.at info) >>= \case
        Just n  -> return n
        Nothing -> do
            nid <- freshNodeId
            let n = BddNode nid var t e
            uniqueTable %= Map.insert info n
            return n
  where
    freshNodeId = do
        lastNodeId += 1
        use lastNodeId

addVariable :: Monad m => Variable -> BuilderT m ()
addVariable (Variable v) = B $ do
    count <- use varCount
    when (v >= count) $ varCount .= v + 1

-- | Create a fresh 'Variable'. The new variable is the maximal element in
-- the variable order.
newVariable :: Monad m => BuilderT m Variable
newVariable = B $ do
    v <- use varCount
    varCount += 1
    return (Variable v)


-- | The terminal node labeled with 'True'.
true :: Bdd
true = BddTerm True

-- | The terminal node labeled with 'False'.
false :: Bdd
false = BddTerm False

-- | Projection function for a 'Variable'.
projection :: Monad m => Variable -> BuilderT m Bdd
projection var = addVariable var >> addNode var true false

not :: Monad m => Bdd -> BuilderT m Bdd
not x = ite x false true

and, or, implies :: Monad m => Bdd -> Bdd -> BuilderT m Bdd
x `and`     y = ite x y    false
x `or`      y = ite x true y
x `implies` y = ite x y    true

-- | @ite cond t e@ creates a 'Bdd' representing @if cond then t else e@.
ite :: Monad m => Bdd -> Bdd -> Bdd -> BuilderT m Bdd
ite c t e = case c of
    BddTerm True       -> return t
    BddTerm False      -> return e
    BddNode _ cVar _ _ -> do
        let var = min (min cVar (variable t)) (variable e)

        t' <- ite (child c var True)  (child t var True)  (child e var True)
        e' <- ite (child c var False) (child t var False) (child e var False)

        if t' == e'
            then return t'
            else addNode var t' e'
  where
    child n var b = case n of
        BddTerm _         -> n
        BddNode _ nodeVar t' e'
          | var < nodeVar -> n
          | otherwise     -> if b then t' else e'

