{-# LANGUAGE OverloadedStrings, GADTs, DataKinds #-}
module AST
    ( AST(..)
    , Expr(..)
    , FunctionCall(..)
    , Stat(..)
    , Token(..)

    , writeAST
    , writeAST'

    , isIdent
    , isNumber
    )
    where
--------------------------------------------------------------------------------
import           Control.Monad.State
import           Data.GraphViz                          (printDotGraph)
import           Data.GraphViz.Types.Monadic
import           Data.GraphViz.Types.Generalised        (DotGraph)
import           Data.GraphViz.Attributes
import           Data.GraphViz.Attributes.Complete
import           Data.Text.Lazy                         (Text)
import qualified Data.Text.Lazy                         as T
import           Text.Printf
import           System.Process                         (system)
--------------------------------------------------------------------------------

data Token
    -- keywords
    = TokenFunction
    | TokenIf
    | TokenElse
    | TokenReturn
    | TokenLet
    | TokenWhile
    -- syntax
    | TokenComma
    | TokenSemicolon
    | TokenLParen
    | TokenRParen
    | TokenLBrace
    | TokenRBrace
    -- literals
    | TokenNumber Int
    | TokenIdent String
    -- exprs
    | TokenNot
    | TokenEqual
    | TokenNotEqual
    | TokenAssign
    | TokenPlus
    | TokenStar
    | TokenMinus
    | TokenSlash
    deriving (Show, Eq)

isIdent :: Token -> Bool
isIdent (TokenIdent _) = True
isIdent _              = False

isNumber :: Token -> Bool
isNumber (TokenNumber _) = True
isNumber _              = False

--------------------------------------------------------------------------------

type Ident = String

data Stat = FunctionStat Ident [Ident] Stat
          | ReturnStat Expr
          | IfStat Expr Stat Stat
          | WhileStat Expr Stat
          | VarStat Ident Expr
          | AssignStat Ident Expr
          | BlockStat [Stat]
          | ExprStat Expr
          | CallStat FunctionCall
          deriving (Show)

data Expr = Call FunctionCall
          | Var Ident
          | LitNum Int
          | Equal Expr Expr
          | NotEqual Expr Expr
          | Add Expr Expr
          | Subtract Expr Expr
          | Multiply Expr Expr
          | Divide Expr Expr
          | Not Expr
          deriving (Show)

data FunctionCall = FunctionCall Ident [Expr]
    deriving (Show)

--------------------------------------------------------------------------------

type DotGen a = StateT Int (DotM Text) a

nodeg :: Attributes -> DotGen Text
nodeg attr = do
    k <- mklabel
    lift $ node k attr
    pure k

class AST a where
    dotAST :: a -> DotGen Text

label :: String -> Attribute
label = textLabel . T.pack

mklabel :: DotGen Text
mklabel = do
    n <- get
    modify succ
    pure $ "L" <> T.pack (show n)

writeAST' :: (AST a) => Maybe a -> IO ()
writeAST' (Just a) = writeAST a

writeAST :: (AST a) => a -> IO ()
writeAST ast = do
    writeFile "/tmp/t.dot" . T.unpack . printDotGraph $ do
        digraph (Str "AST") $ do
            nodeAttrs [shape Record]
            runStateT (dotAST ast) 0

    system "dot -Tsvg /tmp/t.dot > /tmp/t.svg"
    pure ()

dotbin :: (AST a) => String -> a -> a -> DotGen Text
dotbin l a b = do
    p <- nodeg [ label l ]
    q <- dotAST a
    r <- dotAST b
    lift $ do
        p --> q
        p --> r
    pure p

dotunary :: (AST a) => String -> a -> DotGen Text
dotunary l a = do
    p <- nodeg [ label l ]
    q <- dotAST a
    lift $ p --> q
    pure p

addHint :: String -> DotGen Text -> DotGen Text
addHint l a = do
    p <- hint l
    q <- a
    lift $ p --> q
    pure p

hint :: String -> DotGen Text
hint l = nodeg [ label l, shape Ellipse ]

noder :: String -> DotGen Text
noder l = nodeg [ label l ]

--------------------------------------------------------------------------------

instance AST Expr where
    -- atoms
    dotAST (LitNum n) = nodeg [ label $ printf "{ LitNum | %d }" n ]
    dotAST (Var k) = nodeg [ label $ printf "{ Var | %s }" k ]

    -- operators
    dotAST (Not a) = dotunary "Not" a
    dotAST (Equal a b) = dotbin "Equal" a b
    dotAST (Add a b) = dotbin "Add" a b
    dotAST (Subtract a b) = dotbin "Subtract" a b
    dotAST (Multiply a b) = dotbin "Multiply" a b
    dotAST (Divide a b) = dotbin "Divide" a b

    dotAST (Call (FunctionCall f args)) = do
        p <- noder $ printf "{ FunctionCall | %s }" f
        q <- hint "args"
        r <- mapM dotAST args
        lift $ do
            p --> q
            mapM_ (q-->) r
        pure p
    

instance AST Stat where
    dotAST (FunctionStat name params body) = do
        p <- nodeg [ label $
                printf "{ FunctionStat | %s | %s }" name (show params) ]
        q <- dotAST body
        lift $ p --> q
        pure q
    
    dotAST (BlockStat ss) = do
        p <- nodeg [ label "BlockStat" ]

        forM ss $ \s -> do
            q <- dotAST s
            lift $ p --> q

        pure p

    dotAST (ReturnStat e) = do
        p <- nodeg [ label "Return" ]
        q <- dotAST e
        lift $ p --> q
        pure p

    dotAST (IfStat c a b) = do
        p <- nodeg [ label "If" ]
        c' <- addHint "condition" $ dotAST c
        a' <- addHint "then" $ dotAST a
        b' <- addHint "else" $ dotAST b
        lift $ do
            p --> c'
            p --> a'
            p --> b'
        pure p

    dotAST (WhileStat c a) = do
        p <- noder "while"
        c' <- addHint "condition" $ dotAST a
        lift $ p --> c'
        pure p
        


          -- | WhileStat Expr Stat
          -- | VarStat Ident Expr
          -- | AssignStat Ident Expr
    dotAST (ExprStat e) = do
        p <- noder "ExprStat"
        q <- dotAST e
        lift $ p --> q
        pure p
          -- | CallStat FunctionCall
