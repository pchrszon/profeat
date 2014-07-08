{-# LANGUAGE FlexibleContexts, LambdaCase, OverloadedStrings, ViewPatterns #-}

module Template
  ( preprocessExpr

  , unrollRepeatable
  , unrollLoopExprs

  , expandFormulas

  , instantiateWithId
  , instantiate
  , substitute
  ) where

import Control.Applicative
import Control.Lens
import Control.Monad.Either
import Control.Monad.Reader

import Data.Map ( Map )
import qualified Data.Map as Map

import Error
import Symbols
import Syntax
import Typechecker

class Template n where
    parameters :: n a -> [Ident]

preprocessExpr :: ( Applicative m
                  , MonadReader SymbolTable m
                  , MonadEither Error m
                  )
               => LExpr
               -> m LExpr
preprocessExpr e = do
    frms <- view formulas
    expandFormulas frms e >>= unrollLoopExprs

unrollRepeatable :: ( Applicative m
                    , MonadReader SymbolTable m
                    , MonadEither Error m
                    , HasExprs b
                    )
                 => LRepeatable b
                 -> m (LRepeatable b)
unrollRepeatable (Repeatable ss) = Repeatable <$> rewriteM f ss where
    f (s:ss') = case s of
        One _     -> return Nothing
        Many loop -> Just . (++ ss') <$> unrollRepeatableLoop loop
    f [] = return Nothing

unrollRepeatableLoop :: ( Applicative m
                        , MonadReader SymbolTable m
                        , MonadEither Error m
                        , HasExprs b
                        )
                     => LForLoop (Repeatable b)
                     -> m [Some b SrcLoc]
unrollRepeatableLoop = unrollLoop f where
    f (Repeatable ss) = return . concatMap (\defs -> map (substitute defs) ss)

unrollLoopExprs :: ( Applicative m
                   , MonadReader SymbolTable m
                   , MonadEither Error m
                   )
                => LExpr
                -> m LExpr
unrollLoopExprs = rewriteM' $ \case
    LoopExpr loop _ -> Just <$> unrollExprLoop loop
    _               -> return Nothing

unrollExprLoop :: ( Applicative m
                  , MonadReader SymbolTable m
                  , MonadEither Error m
                  )
               => LForLoop Expr
               -> m LExpr
unrollExprLoop = unrollLoop f where
    f e defss = do
        checkLoopBody e
        return $ transformOf plateBody (unrollExpr defss) e

unrollExpr :: [Map Ident LExpr] -> LExpr -> LExpr
unrollExpr defss e = case e of
    BinaryExpr binOp e' (MissingExpr _) _ ->
        let e's = map (`substitute` e') defss
        in foldr1 (binaryExpr binOp) e's
    _ -> e

unrollLoop :: (Applicative m, MonadReader SymbolTable m, MonadEither Error m)
           => (a SrcLoc -> [Map Ident LExpr] -> m b)
           -> LForLoop a
           -> m b
unrollLoop f (ForLoop ident range body _) = do
    range' <- both unrollLoopExprs range

    (lower, upper) <- evalRange range'
    let is | lower <= upper = [lower .. upper]
           | otherwise      = [lower, lower - 1 .. upper]

    f body (map (Map.singleton ident . flip IntegerExpr noLoc) is)

expandFormulas :: (Applicative m, HasExprs n, MonadEither Error m)
               => Map Ident LFormula
               -> n SrcLoc
               -> m (n SrcLoc)
expandFormulas frms = exprs . rewriteM' $ \case
    CallExpr (viewIdentExpr -> Just ident) args l -> call ident args l
    NameExpr (viewIdent -> Just ident) l          -> call ident [] l
    _ -> return Nothing
  where
    call ident args l =
        _Just (fmap frmExpr . instantiate ident args l) (frms^.at ident)

instantiateWithId :: (Template n, HasExprs n, MonadEither Error m)
                  => Integer
                  -> Ident    -- ^ the template name
                  -> [LExpr]  -- ^ the argument list
                  -> SrcLoc   -- ^ 'SrcLoc' where the instantiation happens, required
                              --   for error reporting
                  -> n SrcLoc -- ^ the template
                  -> m (n SrcLoc)
instantiateWithId i ident args l =
    let idDef = Map.singleton "id" $ IntegerExpr i noLoc
    in instantiate ident args l . substitute idDef

instantiate :: (Template n, HasExprs n, MonadEither Error m)
            => Ident    -- ^ the template name
            -> [LExpr]  -- ^ the argument list
            -> SrcLoc   -- ^ 'SrcLoc' where the instantiation happens, required
                        --   for error reporting
            -> n SrcLoc -- ^ the template
            -> m (n SrcLoc)
instantiate ident args l template =
    let params     = parameters template
        paramCount = length params
        argCount   = length args
        defs       = Map.fromList $ zip params args
    in if argCount /= paramCount
           then throw l $ ArityError ident paramCount argCount
           else return $ substitute defs template

substitute :: (HasExprs n) => Map Ident LExpr -> n SrcLoc -> n SrcLoc
substitute defs
  | Map.null defs = id
  | otherwise     = over exprs . transform $ \node -> case node of
    NameExpr (viewIdent -> Just ident) l ->
        maybe node (fmap (reLoc l)) $ defs^.at ident
    _ -> node

-- | Check whether the given expression contains exactly one expression of
-- the form @e * ...@, where @*@ is any binary operator.
checkLoopBody :: (Functor m, MonadEither Error m) => LExpr -> m ()
checkLoopBody e = go e >>= \cnt ->
    when (cnt /= 1) (throw (exprAnnot e) MalformedLoopBody)
  where
    go e' = case e' of
        BinaryExpr _ lhs (MissingExpr _) _
          | has (traverse._MissingExpr) $ universeOf plateBody lhs ->
                throw (exprAnnot lhs) MalformedLoopBody
          | otherwise -> return (1 :: Integer)
        MissingExpr _ -> throw (exprAnnot e') MalformedLoopBody
        _             -> sum <$> mapM go (e'^..plateBody)

-- Traversal of the immediate children of the given expression, ommitting
-- the body of nested 'LoopExpr's.
plateBody :: Traversal' (Expr a) (Expr a)
plateBody f e = case e of
    LoopExpr (ForLoop ident range body a) a' ->
        LoopExpr <$> (ForLoop ident <$> both f range <*> pure body <*> pure a)
                 <*> pure a'
    _ -> plate f e

-- Rewrite by applying the monadic everywhere you can in a top-down manner.
-- Ensures that the rule cannot be applied anywhere in the result.
rewriteM' :: (Monad m, Applicative m, Plated a)
          => (a -> m (Maybe a))
          -> a
          -> m a
rewriteM' = rewriteMOf' plate

rewriteMOf' :: (Monad m) => LensLike' m a a -> (a -> m (Maybe a)) -> a -> m a
rewriteMOf' l f = go where
    go e = f e >>= maybe (l go e) go

instance Template Feature where
    parameters = featParams

instance Template Module where
    parameters = modParams

instance Template Formula where
    parameters = frmParams
