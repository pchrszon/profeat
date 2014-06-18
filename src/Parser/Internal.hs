{-# LANGUAGE ExistentialQuantification #-}

module Parser.Internal
  ( parseFile

  , model
  , definition

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

  , stmt
  , update
  , assign
  , expr
  , name
  ) where

import Control.Applicative
import Control.Lens hiding ( assign )
import Control.Monad.Identity

import Data.List ( foldl' )
import Data.Text.Lazy ( Text, pack )
import Data.Text.Lens

import Text.Parsec hiding ( Error, (<|>), many )
import Text.Parsec.Error ( errorMessages, showErrorMessages )
import Text.Parsec.Expr
import Text.Parsec.Text.Lazy
import qualified Text.Parsec.Token as T

import Error
import SrcLoc
import Syntax

parseFile :: Parser a -> SourceName -> Text -> Either Error a
parseFile p src = over _Left toError . parse (whiteSpace *> p <* eof) src

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
    [ "feature", "endfeature", "global", "const", "formula", "modules", "allOf"
    , "oneOf", "someOf", "of", "optional", "constraint", "rewards", "endrewards"
    , "controller", "endcontroller", "module", "endmodule", "provides"
    , "activate", "deactivate", "array", "bool", "int", "double", "initialize"
    , "for", "endfor", "id", "min", "max", "true", "false"
    ]
reservedOpNames =
    [ "/", "*", "-", "+", "=", "!=", ">", "<", ">=", "<=", "&", "|", "!"
    , "=>", "<=>", "->", "..", "...", "?", ":", ".", "#"
    ]

languageDef :: T.GenLanguageDef Text () Identity
languageDef = T.LanguageDef
    { T.commentStart    = "/*"
    , T.commentEnd      = "*/"
    , T.commentLine     = "//"
    , T.nestedComments  = True
    , T.identStart      = letter <|> char '_'
    , T.identLetter     = alphaNum <|> char '_'
    , T.opStart         = oneOf "/*-+=!><&|.?:#"
    , T.opLetter        = oneOf "=.>"
    , T.reservedNames   = reservedNames
    , T.reservedOpNames = reservedOpNames
    , T.caseSensitive   = True
    }

lexer :: T.GenTokenParser Text () Identity
lexer = T.makeTokenParser languageDef

integer :: (Integral a) => Parser a
integer = fromInteger <$> T.integer lexer

float :: Parser Double
float = T.float lexer

bool :: Parser Bool
bool = False <$ reserved "false"
   <|> True  <$ reserved "true"

identifier :: Parser Text
identifier = pack <$> T.identifier lexer

reserved, reservedOp :: String -> Parser ()
reserved   = T.reserved lexer
reservedOp = T.reservedOp lexer

symbol :: String -> Parser String
symbol = T.symbol lexer

dot, semi, colon :: Parser String
dot   = T.dot lexer
semi  = T.semi lexer
colon = T.colon lexer

parens, brackets, braces, doubleQuotes :: forall a. Parser a -> Parser a
parens       = T.parens lexer
brackets     = T.brackets lexer
braces       = T.braces lexer
doubleQuotes = let quote = symbol "\"" in between quote quote

commaSep, commaSep1 :: Parser a -> Parser [a]
commaSep  = T.commaSep  lexer
commaSep1 = T.commaSep1 lexer

whiteSpace :: Parser ()
whiteSpace = T.whiteSpace lexer

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
model = Model <$> many definition

definition :: Parser LDefinition
definition = choice [ featureDef
                    , controllerDef
                    , moduleDef
                    , globalDef
                    , constantDef
                    , formulaDef
                    ]

featureDef :: Parser LDefinition
featureDef = FeatureDef <$> feature <?> "feature"

feature :: Parser LFeature
feature = loc $ do
    reserved "feature"
    ident <- identifier
    ps    <- params
    block "feature" $
        Feature ident ps <$> optionMaybe decomposition
                         <*> many constraint
                         <*> moduleList
                         <*> many rewards
  where
    moduleList = option [] $ reserved "modules" *> colon *> commaSep1 inst <* semi

constraint :: Parser LExpr
constraint = reserved "constraint" *> colon *> expr <* semi

decomposition :: Parser LDecomposition
decomposition = loc (Decomposition <$> (decompOp <* colon)
                                   <*> (commaSep1 featureRef <* semi))
             <?> "decomposition"

decompOp :: Parser LDecompOp
decompOp =  AllOf  <$  reserved "allOf"
        <|> OneOf  <$  reserved "oneOf"
        <|> SomeOf <$  reserved "someOf"
        <|> Group  <$> range
        <?> "decomposition operator"

featureRef :: Parser LFeatureRef
featureRef = FeatureRef <$> option False (True <$ reserved "optional")
                        <*> inst
                        <*> optionMaybe (brackets expr)

inst :: Parser LInstance
inst = loc $ Instance <$> identifier <*> option [] args

rewards :: Parser LRewards
rewards = Rewards <$> (reserved "rewards" *> doubleQuotes identifier)
                  <*> block "rewards" (many reward)
                  <?> "rewards"

reward :: Parser LReward
reward = loc (Reward <$> brackets actionLabel
                     <*> (expr <* colon)
                     <*> (expr <* semi))
      <?> "cost"

controllerDef :: Parser LDefinition
controllerDef = ControllerDef . Controller <$>
    (reserved "controller" *> block "controller" moduleBody)

moduleDef :: Parser LDefinition
moduleDef = fmap ModuleDef $ do
    reserved "module"
    ident <- identifier
    ps    <- params
    block "module" $ Module ident ps <$> provides <*> moduleBody
  where
    provides = option [] $
        reserved "provides" *> colon *> commaSep1 identifier <* semi

moduleBody :: Parser LModuleBody
moduleBody = loc (ModuleBody <$> many varDecl <*> repeatable stmt many)

globalDef :: Parser LDefinition
globalDef = GlobalDef <$> (reserved "global" *> varDecl)
         <?> "variable declaration"

varDecl :: Parser LVarDecl
varDecl = loc (VarDecl <$> identifier <* colon
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
                  <*> (identifier <* reservedOp "=")
                  <*> (expr <* semi)) <?> "constant definition"

constantType :: Parser ConstType
constantType =  BoolConstType   <$ reserved "bool"
            <|> IntConstType    <$ reserved "int"
            <|> DoubleConstType <$ reserved "double"
            <?> "type"

formulaDef :: Parser LDefinition
formulaDef = FormulaDef <$> formula

formula :: Parser LFormula
formula = loc (Formula <$> identifier
                       <*> params
                       <*> (reservedOp "=" *> expr))
       <?> "formula"

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
    [ ActInitialize <$ reserved "initialize"
    , ActActivate   <$ reserved "activate"
    , ActDeactivate <$ reserved "deactivate"
    , Action <$> name
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
    , Deavtivate <$> (reserved "deactivate" *> parens name)
    , parens $ Assign <$> name <* symbol "'" <* reservedOp "=" <*> expr
    ]) <?> "assignment"

expr :: Parser LExpr
expr = do
    e <- simpleExpr
    option e . loc $ CondExpr e <$> (reservedOp "?" *> expr) <*> (colon *> expr)
  where
    simpleExpr = buildExpressionParser opTable term <?> "expression"

term :: Parser LExpr
term =  parens expr
    <|> loc (choice
            [ MissingExpr <$ reservedOp "..."
            , BoolExpr <$> bool
            , DecimalExpr <$> try float
            , IntegerExpr <$> integer
            , LoopExpr <$> forLoop expr
            , try (FuncExpr <$> function <*> args)
            , NameExpr <$> name
            ])

repeatable :: Parser (b SrcLoc)
           -> (Parser (Some b SrcLoc) -> Parser [Some b SrcLoc])
           -> Parser (LRepeatable b)
repeatable p c = Repeatable <$> c some'
  where
    some' =  Many <$> forLoop (repeatable p c)
         <|> One  <$> p

forLoop :: Parser (b SrcLoc) -> Parser (LForLoop b)
forLoop p = loc (ForLoop <$> (reserved "for" *> identifier)
                         <*> (reserved "in"  *> range)
                         <*> block "for" p)
         <?> "for loop"

function :: Parser Function
function = choice
    [ FuncMin   <$  reserved "min"
    , FuncMax   <$  reserved "max"
    , FuncFloor <$  reserved "floor"
    , FuncCeil  <$  reserved "ceil"
    , FuncPow   <$  reserved "pow"
    , FuncMod   <$  reserved "mod"
    , FuncLog   <$  reserved "log"
    , Func      <$> identifier
    ] <?> "function call"

name :: Parser LName
name = foldl' (flip ($)) <$> (Name <$> baseName) <*> many qualifier
  where
    qualifier = choice
        [ dot *> (flip Member <$> baseName)
        , flip Index <$> brackets expr
        ] <?> "qualifier"

baseName :: Parser LBaseName
baseName = loc $ BaseName <$> identifier <*> many (reservedOp "#" *> expr)

args :: Parser [LExpr]
args = parens (commaSep expr)

params :: Parser [Ident]
params = option [] . parens $ commaSep1 identifier

range :: Parser LRange
range = brackets ((,) <$> expr <*> (reservedOp ".." *> expr))

opTable :: OperatorTable Text () Identity LExpr
opTable = -- operators listed in descending precedence, operators in same group have the same precedence
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

unary :: ParsecT s u m a -> UnOp -> Operator s u m (Expr b)
unary p unOp = Prefix (unaryExpr unOp <$ p)

binary :: Assoc -> ParsecT s u m a -> BinOp -> Operator s u m (Expr b)
binary assoc p binOp = Infix (binaryExpr binOp <$ p) assoc

