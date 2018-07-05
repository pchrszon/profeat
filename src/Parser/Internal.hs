{-# OPTIONS_GHC -fno-warn-missing-signatures #-}
{-# OPTIONS_GHC -fno-warn-unused-binds       #-}

{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RecordWildCards           #-}

module Parser.Internal
  ( Language(..)
  , parseFile
  , parseFile'

  , model
  , specification

  , familyDef
  , family'

  , featureDef
  , feature
  , constraint
  , decomposition
  , rewards

  , controllerDef
  , moduleDef
  , moduleBody

  , globalDef
  , varDecl
  , varType
  , compoundVarType
  , simpleVarType

  , constantDef
  , constantType

  , formulaDef
  , formula

  , labelDef
  , label

  , propertyDef
  , property

  , stmt
  , update
  , assign
  , expr
  , name
  ) where

import Control.Lens hiding ( assign )
import Control.Monad.Identity

import Data.List.NonEmpty
import Data.Monoid
import Data.Text.Lazy ( Text, pack )
import Data.Text.Lens

import Text.Parsec hiding ( Reply(..), label )
import Text.Parsec.Error ( errorMessages, showErrorMessages )
import Text.Parsec.Expr
import qualified Text.Parsec.Token as T
import Text.Parsec.Text.Lazy ()

import Error
import Syntax
import Syntax.Util
import Types

data Language = PrismLang | ProFeat

type UserState = Language
type Parser    = Parsec Text UserState

parseFile :: Parser a -> SourceName -> Text -> Either Error a
parseFile = parseFile' ProFeat

parseFile' :: Language -> Parser a -> SourceName -> Text -> Either Error a
parseFile' lang p src =
    over _Left toError . runParser (whiteSpace *> p <* eof) lang src

-- | Converts a 'ParseError' to an 'Error'.
toError :: ParseError -> Error
toError = Error <$> toSrcLoc . errorPos <*> toSyntaxError

-- | Converts Parsec's 'SourcePos' to a 'SrcLoc'.
toSrcLoc :: SourcePos -> SrcLoc
toSrcLoc = srcLoc <$> pack . sourceName <*> sourceLine <*> sourceColumn

-- | Converts Parsec's error message to an 'ErrorDesc'.
toSyntaxError :: ParseError -> ErrorDesc
toSyntaxError = SyntaxError . pack .
    showErrorMessages msgOr msgUnknown msgExpecting msgUnExpected msgEOF .
    errorMessages
  where
    msgOr         = "or"
    msgUnknown    = "unkown parse error"
    msgExpecting  = "expecting"
    msgUnExpected = "unexpected"
    msgEOF        = "end of input"

reservedNames, reservedOpNames :: [String]
reservedNames =
    [ "mdp", "dtmc", "ctmc", "family", "endfamily", "features", "feature"
    , "endfeature", "root", "global", "const", "formula", "label", "modules"
    , "all", "one", "some", "of", "optional", "as", "constraint", "initial"
    , "rewards", "endrewards", "controller", "endcontroller", "module"
    , "endmodule", "this", "active", "iactive", "activate", "deactivate"
    , "array", "bool", "int", "double", "init", "endinit", "invariant"
    , "endinvariant", "for", "endfor", "in", "id", "block", "filter", "min"
    , "max", "quantile", "sample", "reward", "true", "false", "P", "R", "S", "E"
    , "A", "U", "W", "R", "X", "F", "G", "C", "I"
    ]
reservedOpNames =
    [ "/", "*", "-", "+", "=", "!=", ">", "<", ">=", "<=", "&", "|", "!"
    , "=>", "<=>", "->", "..", "...", "?", "."
    ]

languageDef :: T.GenLanguageDef Text UserState Identity
languageDef = T.LanguageDef
    { T.commentStart    = "/*"
    , T.commentEnd      = "*/"
    , T.commentLine     = "//"
    , T.nestedComments  = True
    , T.identStart      = getState >>= \case
                              PrismLang -> char '_' <|> letter
                              ProFeat   -> letter
    , T.identLetter     = alphaNum <|> char '_'
    , T.opStart         = oneOf "/*-+=!><&|.?"
    , T.opLetter        = oneOf "=.>?"
    , T.reservedNames   = reservedNames
    , T.reservedOpNames = reservedOpNames
    , T.caseSensitive   = True
    }

lexer :: T.GenTokenParser Text UserState Identity
lexer = T.makeTokenParser languageDef

T.TokenParser{..} = lexer

decimal' :: Parser Text
decimal' = T.lexeme lexer $ try $ do
    w <- many digit
    option (pack w) $ do
        void $ char '.'
        f <- many1 digit
        return . pack $ w ++ '.':f

bool :: Parser Bool
bool = False <$ reserved "false"
   <|> True  <$ reserved "true"

identifier' :: Parser Text
identifier' = pack <$> identifier

doubleQuotes :: forall a. Parser a -> Parser a
doubleQuotes = let quote = symbol "\"" in between quote quote

block :: String -> Parser a -> Parser a
block blockName p = braces p <|> (p <* reserved ("end" ++ blockName))

-- | The loc combinator annotates the value parsed by @p@ with its location
-- in the source file.
loc :: Parser (SrcLoc -> a) -> Parser a
loc p = do
    pos <- getPosition
    let src    = sourceName pos^.packed
        line   = sourceLine pos
        column = sourceColumn pos
    ($ srcLoc src line column) <$> p

model :: Parser LModel
model = do
    lang <- getState
    Model <$> modelType <*> many (choice $ definitions lang)
  where
    definitions ProFeat   = [ familyDef
                            , featureDef
                            , controllerDef
                            , moduleDef
                            , globalDef
                            , constantDef
                            , formulaDef
                            , labelDef
                            , initDef
                            , invariantDef
                            ]
    definitions PrismLang = [ moduleDef
                            , globalDef
                            , constantDef
                            , formulaDef
                            , labelDef
                            , initDef
                            , rewardsDef
                            ]

modelType :: Parser ModelType
modelType = option defaultModelType $ choice
  [ MDP  <$ reserved "mdp"
  , DTMC <$ reserved "dtmc"
  , CTMC <$ reserved "ctmc"
  ]

specification :: Parser LSpecification
specification = Specification <$> many (choice [ constantDef
                                               , formulaDef
                                               , labelDef
                                               , propertyDef
                                               ])

familyDef :: Parser LDefinition
familyDef = FamilyDef <$> family' <?> "family declaration"

family' :: Parser LFamily
family' = loc $ reserved "family" *> block "family"
    (Family <$> many varDecl <*> many constr <*> features)
  where
    constr = reserved "initial" *> reserved "constraint" *> expr <* semi
    features = option [] (reserved "features" *> commaSep1 name <* semi)

featureDef :: Parser LDefinition
featureDef = FeatureDef <$> feature <?> "feature"

feature :: Parser LFeature
feature = loc $ do
    isRoot <- option False (True <$ reserved "root")
    reserved "feature"
    ident <- if isRoot
                then return "root"
                else identifier'
    ps    <- params
    block "feature" $
        Feature isRoot ident ps
            <$> many varDecl
            <*> optionMaybe decomposition
            <*> many constraint
            <*> blockList
            <*> moduleList
            <*> many rewards
  where
    blockList  = option [] $ reserved "block" *> commaSep1 name <* semi
    moduleList = option [] $ reserved "modules" *> commaSep1 inst <* semi

constraint :: Parser LConstraint
constraint = loc $ Constraint <$> option False (True <$ reserved "initial")
                              <*> (reserved "constraint" *> expr <* semi)

decomposition :: Parser LDecomposition
decomposition = loc (Decomposition <$> (decompOp <* reserved "of")
                                   <*> (commaSep1 featureRef <* semi))
             <?> "decomposition"

decompOp :: Parser LDecompOp
decompOp =  AllOf  <$  reserved "all"
        <|> OneOf  <$  reserved "one"
        <|> SomeOf <$  reserved "some"
        <|> Group  <$> range
        <?> "decomposition operator"

featureRef :: Parser LFeatureRef
featureRef = FeatureRef <$> option False (True <$ reserved "optional")
                        <*> inst
                        <*> optionMaybe (reserved "as" *> identifier')
                        <*> optionMaybe (brackets expr)

inst :: Parser LInstance
inst = loc $ Instance <$> identifier' <*> option [] (args expr)

rewardsDef :: Parser LDefinition
rewardsDef = RewardsDef <$> rewards

rewards :: Parser LRewards
rewards = loc (Rewards <$> (reserved "rewards" *> doubleQuotes identifier')
                       <*> block "rewards" (repeatable reward many)) <?> "rewards"

reward :: Parser LReward
reward = loc (Reward <$> optionMaybe (brackets actionLabel)
                     <*> (expr <* colon)
                     <*> (expr <* semi))
      <?> "reward"

controllerDef :: Parser LDefinition
controllerDef = ControllerDef . Controller <$>
    (reserved "controller" *> block "controller" moduleBody)

moduleDef :: Parser LDefinition
moduleDef = fmap ModuleDef $ do
    reserved "module"
    ident <- identifier'
    ps    <- params
    block "module" $ Module ident ps <$> moduleBody

moduleBody :: Parser LModuleBody
moduleBody = loc (ModuleBody <$> many varDecl <*> repeatable stmt many)

globalDef :: Parser LDefinition
globalDef = GlobalDef <$> (reserved "global" *> varDecl)
         <?> "variable declaration"

varDecl :: Parser LVarDecl
varDecl = loc (VarDecl <$> identifier' <* colon
                       <*> varType
                       <*> optionMaybe (reserved "init" *> expr) <* semi)
       <?> "variable declaration"

varType :: Parser LVarType
varType = choice [ CompoundVarType <$> compoundVarType
                 , SimpleVarType   <$> simpleVarType
                 ]
       <?> "type"

compoundVarType :: Parser LCompoundVarType
compoundVarType = ArrayVarType <$> (reserved "array" *> range)
                               <*> (reserved "of" *> simpleVarType)
               <?> "type"

simpleVarType :: Parser LSimpleVarType
simpleVarType =  BoolVarType <$  reserved "bool"
             <|> IntVarType  <$> range
             <?> "base type"

constantDef :: Parser LDefinition
constantDef = ConstDef <$>
    loc (Constant <$> (reserved "const" *>
                       option IntConstType constantType)
                  <*> identifier'
                  <*> optionMaybe (reservedOp "=" *> expr) <* semi)
  <?> "constant definition"

constantType :: Parser ConstType
constantType =  BoolConstType   <$ reserved "bool"
            <|> IntConstType    <$ reserved "int"
            <|> DoubleConstType <$ reserved "double"
            <?> "type"

formulaDef :: Parser LDefinition
formulaDef = FormulaDef <$> formula

formula :: Parser LFormula
formula = loc (Formula <$> (reserved "formula" *> identifier')
                       <*> params
                       <*> (reservedOp "=" *> expr <* semi))
       <?> "formula"

labelDef :: Parser LDefinition
labelDef = LabelDef <$> label

label :: Parser LLabel
label = loc (Label <$> (reserved "label" *> doubleQuotes identifier')
                   <*> (reservedOp "=" *> expr <* semi))
     <?> "label definition"

initDef :: Parser LDefinition
initDef = InitDef <$> init' <?> "init definition"

init' :: Parser LInit
init' = loc (Init <$> (reserved "init" *> block "init" expr))

invariantDef :: Parser LDefinition
invariantDef = InvariantDef <$> invariant <?> "invariant definition"

invariant :: Parser LInvariant
invariant = loc (Invariant <$> (reserved "invariant" *> block "invariant" expr))

propertyDef :: Parser LDefinition
propertyDef = PropertyDef <$>
    loc (Property <$> propertyIdent <*> property <* semi) <?> "property"
  where
    propertyIdent = option Nothing (Just <$> doubleQuotes identifier' <* colon)

stmt :: Parser LStmt
stmt =  loc (Stmt <$> brackets actionLabel
                  <*> expr <* reservedOp "->"
                  <*> updates)
    <?> "statement"
  where
    updates =  Repeatable [] <$ try (reserved "true" <* semi)
           <|> try (singleUpdate <* semi)
           <|> repeatable update (`sepBy1` reservedOp "+") <* semi
    singleUpdate = fmap (Repeatable . (:[]) . One) . loc $
        Update Nothing <$> assigns

actionLabel :: Parser LActionLabel
actionLabel = option NoAction . loc . choice $
    [ ActActivate   <$  reserved "activate"
    , ActDeactivate <$  reserved "deactivate"
    , Action        <$> name
    ]

update :: Parser LUpdate
update = loc (Update <$> probability <*> assignmentList) <?> "stochastic update"
  where
    probability    = Just <$> (expr <* colon)
    assignmentList =  Repeatable [] <$ reserved "true"
                  <|> assigns

assigns :: Parser (LRepeatable Assign)
assigns = repeatable assign (`sepBy1` reservedOp "&")

assign :: Parser LAssign
assign = loc (choice
    [ Activate   <$> (reserved "activate"   *> parens name)
    , Deactivate <$> (reserved "deactivate" *> parens name)
    , parens $ Assign <$> name <* symbol "'" <* reservedOp "=" <*> expr
    ]) <?> "assignment"

expr :: Parser LExpr
expr = expr' False

property :: Parser LExpr
property = expr' True

-- | Creates the expression parser. If @allowPctl@ is 'True' the parser
-- will accept temporal and probabilistic operators.
expr' :: Bool -> Parser LExpr
expr' allowPctl = simpleExpr >>= condExpr
  where
    simpleExpr =
        normalizeExpr <$> buildExpressionParser opTable (term allowPctl)
                      <?> "expression"
    condExpr e = option e $ CondExpr e <$> (reservedOp "?" *> expr' allowPctl)
                                       <*> (colon *> expr' allowPctl)
                                       <*> pure (exprAnnot e)
    opTable
      | allowPctl = exprOpTable ++ pctlOpTable -- order is important here, PCTL operators have lower precedence
      | otherwise = exprOpTable

term :: Bool -> Parser LExpr
term allowPctl = atom allowPctl >>= callExpr
  where
    callExpr e = option e $ CallExpr e <$> args (expr' allowPctl)
                                       <*> pure (exprAnnot e)

atom :: Bool -> Parser LExpr
atom allowPctl
    = parens (expr' allowPctl)
   <|> loc (choice $ pctlExpr ++
                   [ MissingExpr     <$  reservedOp "..."
                   , idExpr          <$  reserved "id"
                   , BoolExpr        <$> bool
                   , DecimalExpr     <$> try float
                   , IntegerExpr     <$> integer
                   , LoopExpr        <$> forLoop (expr' allowPctl)
                   , filterExpr allowPctl
                   , labelExpr allowPctl
                   , arrayExpr
                   , sampleExpr
                   , FuncExpr        <$> function
                   , NameExpr        <$> name
                   ])
   <?> "literal, variable or expression"
  where
    idExpr l = NameExpr (_Ident # ("id", l)) l
    pctlExpr
      | allowPctl = [ UnaryExpr <$> stateOp <*> brackets (expr' allowPctl)
                    , quantileExpr
                    , conditionalExpr
                    ]
      | otherwise = []
    stateOp = choice
        [ TempUnOp Exists <$ reserved "E"
        , TempUnOp Forall <$ reserved "A"
        ]

conditionalExpr :: Parser (SrcLoc -> LExpr)
conditionalExpr = do
    prop <- loc (probExpr <|> rewardExpr <|> steadyExpr)
    option (const prop) (ConditionalExpr prop <$> brackets property)

probExpr :: Parser (SrcLoc -> LExpr)
probExpr = symbol "P" *> (ProbExpr <$> bound <*> brackets property)

rewardExpr :: Parser (SrcLoc -> LExpr)
rewardExpr = RewardExpr
    <$> (symbol "R" *> optionMaybe (braces struct))
    <*> bound
    <*> brackets rewardProp
  where
    struct = loc (labelExpr True) <|> expr

rewardProp :: Parser LRewardProp
rewardProp = choice
  [ Reachability <$> (reserved "F" *> expr' True)
  , Cumulative   <$> (reserved "C" *> reservedOp "<=" *> decimal')
  , Instant      <$> (reserved "I" *> reservedOp "="  *> decimal')
  , Steady       <$   reserved "S"
  ]

steadyExpr :: Parser (SrcLoc -> LExpr)
steadyExpr = symbol "S" *> (SteadyExpr <$> bound <*> brackets property)

quantileExpr :: Parser (SrcLoc -> LExpr)
quantileExpr = reserved "quantile" *>
    parens (QuantileExpr <$> minMax <*> identifier' <*> (comma *> property))

bound :: Parser LBound
bound = Bound <$> optionMaybe minMax <*> boundOp' <*> choice
    [ [] <$ reservedOp "?"
    , braces (commaSep1 expr)
    , (:[]) <$> expr
    ]

minMax :: Parser MinMax
minMax = choice [Min <$ reserved "min", Max <$ reserved "max"]

repeatable :: Parser (b SrcLoc)
           -> (Parser (Some b SrcLoc) -> Parser [Some b SrcLoc])
           -> Parser (LRepeatable b)
repeatable p c = Repeatable <$> c some'
  where
    some' =  Many <$> forLoop (repeatable p c)
         <|> One  <$> p

forLoop :: Parser (b SrcLoc) -> Parser (LForLoop b)
forLoop p = loc (ForLoop <$> (reserved "for" *> identifier')
                         <*> (reserved "in"  *> range)
                         <*> block "for" p)
         <?> "for loop"

sampleExpr :: Parser (SrcLoc -> LExpr)
sampleExpr = SampleExpr <$> (reserved "sample" *> parens (commaSep sampleArg))
  where
    sampleArg =
        (ArgString <$> doubleQuotes identifier') <|>
        (ArgExpr <$> expr)

filterExpr :: Bool -> Parser (SrcLoc -> LExpr)
filterExpr False = parserZero
filterExpr True  = reserved "filter" *> parens
    (FilterExpr <$> filterOp
                <*> (comma *> property)
                <*> optionMaybe (comma *> property))

labelExpr :: Bool -> Parser (SrcLoc -> LExpr)
labelExpr False = parserZero
labelExpr True  = LabelExpr <$> doubleQuotes labelIdent <?> "label"
  where
    labelIdent =  "init" <$ reserved "init"
              <|> identifier'

arrayExpr :: Parser (SrcLoc -> LExpr)
arrayExpr = ArrayExpr . fromList <$> braces (commaSep1 expr)

filterOp :: Parser FilterOp
filterOp = choice
    [ "min"      --> FilterMin
    , "max"      --> FilterMax
    , "argmin"   --> FilterArgmin
    , "argmax"   --> FilterArgmax
    , "count"    --> FilterCount
    , "sum"      --> FilterSum
    , "avg"      --> FilterAvg
    , "first"    --> FilterFirst
    , "range"    --> FilterRange
    , "forall"   --> FilterForall
    , "exists"   --> FilterExists
    , "print"    --> FilterPrint
    , "printall" --> FilterPrintall
    , "state"    --> FilterState
    ] <?> "filter operator"
  where
    s --> fOp = fOp <$ reserved s

function :: Parser Function
function = choice
    [ "min"     --> FuncMin
    , "max"     --> FuncMax
    , "floor"   --> FuncFloor
    , "ceil"    --> FuncCeil
    , "pow"     --> FuncPow
    , "mod"     --> FuncMod
    , "log"     --> FuncLog
    , "active"  --> FuncActive
    , "iactive" --> FuncIActive
    , "binom"   --> FuncBinom
    ] <?> "function call"
  where
    s --> func = func <$ reserved s

stepBound :: Parser (Maybe StepBound)
stepBound = optionMaybe $ choice
  [ StepBound <$> boundOp' <*> decimal'
  , brackets (BoundInterval <$> decimal' <*> (comma *> decimal'))
  , braces (RewardBound
        <$> (reserved "reward" *> braces (doubleQuotes identifier'))
        <*> boundOp'
        <*> (identifier' <|> decimal'))
  ]

boundOp' :: Parser BoundOp
boundOp' = choice
    [ ">=" --> BGte
    , "<=" --> BLte
    , ">"  --> BGt
    , "<"  --> BLt
    , "="  --> BEq
    ]
  where
    s --> bOp = bOp <$ try (symbol s)

name :: Parser LName
name =  loc (toName <$> (this <|> qualifier)
                    <*> many (reservedOp "." *> qualifier))
    <?> "name"
  where
    toName q qs = Name (q :| qs)
    this        = ("this", Nothing) <$ reserved "this"
    qualifier   = (,) <$> identifier' <*> optionMaybe (brackets expr)

args :: Parser LExpr -> Parser [LExpr]
args = parens . commaSep

params :: Parser [Ident]
params = option [] . parens $ commaSep1 identifier'

range :: Parser LRange
range = brackets ((,) <$> expr <*> (reservedOp ".." *> expr))

exprOpTable :: OperatorTable Text UserState Identity LExpr
exprOpTable = -- operators listed in descending precedence, operators in same group have the same precedence
    [ [ unaryOp "-" $ ArithUnOp Neg
      ]
    , [ "*"   --> ArithBinOp Mul
      , "/"   --> ArithBinOp Div
      ]
    , [ "+"   --> ArithBinOp Add
      , "-"   --> ArithBinOp Sub
      ]
    , [ "="   --> EqBinOp Eq
      , "!="  --> EqBinOp Neq
      , ">"   --> RelBinOp Gt
      , "<"   --> RelBinOp Lt
      , ">="  --> RelBinOp Gte
      , "<="  --> RelBinOp Lte
      ]
    , [ unaryOp "!" $ LogicUnOp LNot
      ]
    , [ "&"   --> LogicBinOp LAnd
      ]
    , [ "|"   --> LogicBinOp LOr
      ]
    , [ "=>"  --> LogicBinOp LImpl
      , "<=>" --> LogicBinOp LEq
      ]
    ]
  where
    unaryOp s     = unary $ reservedOp s
    (-->) s = binary AssocLeft $ reservedOp s

pctlOpTable :: OperatorTable Text UserState Identity LExpr
pctlOpTable =
    [ [ Prefix tempUnOps ]
    , [ "U" --> Until
      , "W" --> WeakUntil
      , "R" --> Release
      ]
    ]
  where
    tempUnOps = appEndo . foldMap (Endo . unaryExpr) <$> many1 tempUnOp -- Note [unary temporal operators] (see below)
    tempUnOp = TempUnOp <$> choice
        [ Next <$ reserved "X"
        , reserved "F" *> (Finally  <$> stepBound)
        , reserved "G" *> (Globally <$> stepBound)
        ]
    s --> binOp = Infix
        (reserved s *> (binaryExpr . TempBinOp . binOp <$> stepBound))
        AssocNone

{- Note [unary temporal operators]
- Prefix operators of the same precedence (like X, F and G) can only occur once
- (see Parsec doc for details) and thus would require superfluous
- parentheses. To overcome this limitation a sequence of X, F and
- G operators is folded to appear as a single operator. Using the same
- approach one could allow sequencing of the ! operator.
-}

unary :: ParsecT s u m a -> UnOp -> Operator s u m (Expr b)
unary p unOp = Prefix (unaryExpr unOp <$ p)

binary :: Assoc -> ParsecT s u m a -> BinOp -> Operator s u m (Expr b)
binary assoc p binOp = Infix (binaryExpr binOp <$ p) assoc

