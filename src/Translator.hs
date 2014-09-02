{-# LANGUAGE FlexibleContexts, LambdaCase, OverloadedStrings #-}

module Translator
  ( translateModel
  ) where

import Control.Applicative
import Control.Lens
import Control.Monad.Reader

import Data.Foldable ( toList )
import Data.Map ( assocs )
import Data.Traversable

import Error
import Symbols
import Syntax

import Translator.Common
import Translator.Constraints
import Translator.Controller
import Translator.Modules
import Translator.Rewards

translateModel :: SymbolTable -> Either Error LModel
translateModel symTbl = do
    (initConstrs, constrs) <- runReaderT extractConstraints (Env Global symTbl)

    flip runReaderT (trnsInfo symTbl constrs) $ do
        (controllerDef, lss) <- trnsControllerDef initConstrs
        local (labelSets .~ lss) $ do
            constDefs     <- trnsConsts
            globalDefs    <- trnsGlobals
            moduleDefs    <- trnsModules
            rewardsDefs   <- trnsRewards

            return . Model $ concat [ constDefs
                                    , globalDefs
                                    , moduleDefs
                                    , toList controllerDef
                                    , rewardsDefs
                                    ]

trnsConsts :: Trans [LDefinition]
trnsConsts = fmap toConstDef <$> view (constants.to assocs)
  where
    toConstDef (ident, ConstSymbol l _ ct e) = ConstDef $ Constant ct ident e l

trnsGlobals :: Trans [LDefinition]
trnsGlobals = do
    globalTbl <- view globals
    fmap concat . for (globalTbl^..traverse) $ \(GlobalSymbol t decl) ->
        fmap GlobalDef <$> trnsVarDecl t decl

