{-# LANGUAGE OverloadedStrings, TypeFamilies, NegativeLiterals #-}
module CodeGen
    ( emit
    )
    where
--------------------------------------------------------------------------------
import           Control.Monad
import           Control.Exception              (assert)
import           Control.Monad.State
import           Data.Foldable                  (traverse_)
import           Data.Default                   (Default(def))
import           Data.Kind
import           Text.Printf                    (printf)
import ARM
import AST
--------------------------------------------------------------------------------
data UState = UState
    { usBindings :: [(Ident, Int)]
    }

instance Default UState where
    def = UState
        { usBindings = []
        }

class CodeGen a where
    -- | emit into a given register; default will not be effecient
    emitTo :: Reg -> a -> ARM UState ()
    -- | emits some assembly
    emit :: a -> ARM UState ()

    emitTo rd a = emit a >> mov r0 rd
    emit = emitTo r0
    {-# MINIMAL emit | emitTo #-}
--------------------------------------------------------------------------------

instance CodeGen Stat where
    emitTo _ (FunctionStat vis name pars body) = do
        comment $ printf "function %s()" name
        let l = toLabel name
        
        when (vis == Public) $
            global l
        label l
        
        -- push [fp, lr]
        -- emit body
        -- pop [fp, pc]
        prologue
        emit body
        epilogue

        where
            prologue = do
                push [fp, lr]
                mov fp sp
                push [r0, r1, r2, r3]
                forM_ (pars `zip` [0,4..]) $ \(p,n) ->
                    addBinding p (n - 16)
            epilogue = do
                mov sp fp
                pop [fp, pc]

    -- function calls always return to r0
    emitTo rd (CallStat fncl) = emitTo rd fncl

    emitTo _ (LabelStat name) = do
        label (toLabel name)

    emitTo _ (GotoStat name) = do
        branch (toLabel name)

    emitTo _ (IfStat cond thn els) = do
        pastElse <- allocLabel
        toElse <- allocLabel
        emitTo r0 cond
        cmp r0 #0
        -- if falsey, jump to else
        beq toElse

        -- do then-clause and jump past else-clause
        emit thn
        branch pastElse

        label toElse
        emit els
        label pastElse

    -- if-statements with no else-clause use empty block stats
    emitTo _ (BlockStat []) = pure ()
    emitTo _ (BlockStat ss) = traverse_ emit ss

    emitTo rd (AssertStat e) = do
        comment "assert"
        emitTo r0 e
        cmp r0 #0
        movne r0 '.'
        moveq r0 'F'
        bl "putchar"
        
    emitTo _ (ReturnStat e) = do
        comment "return"
        -- functions should return to r0
        emitTo r0 e
        mov sp fp
        pop [fp, pc]

    -- emitTo rd (LetStat k v) = do
    --     emitTo rd v

instance CodeGen Expr where

    emitTo rd (Var k) = do
        m <- gets (lookup k . usBindings)
        case m of
            Just a -> ldr r0 (fp, a)
            Nothing -> error $ printf "undefined variable: %s" k

    emitTo rd (LitNum n) = comment "litnum" >> ldr rd n

    emitTo rd (Equal a b) = do
        comment "=="
        binop a b $ do
            cmp r0 r1
            moveq rd #1
            movne rd #0

    emitTo rd (NotEqual a b) = do
        comment "!="
        binop a b $ do
            cmp r0 r1
            movne rd #1
            moveq rd #0

    emitTo rd (CmpLT a b) =
        binop a b $ do
            cmp r0 r1
            movlt rd #1
            movge rd #0

    emitTo rd (Multiply a b) = do
        comment "*"
        binop a b $ do
            mul rd r0 r1

    emitTo rd (Divide a b) = do
        comment "/"
        binop a b $ do
            udiv rd r0 r1

    emitTo rd (Add a b) = do
        comment "+"
        binop a b $ do
            add rd r0 r1

    emitTo rd (Subtract a b) = do
        comment "-"
        binop a b $ do
            sub rd r0 r1

    emitTo rd (Not e) = do
        comment "!"
        emitTo rd e
        cmp rd #0
        movne rd #0
        moveq rd #1

    emitTo rd (Dereference e) = do
        emitTo rd e
        ldr rd [rd]

    -- temp; emit using LValue newtype instance with errors on non-lvalues
    emitTo rd (Reference (Var k)) = do
        m <- gets (lookup k . usBindings)
        case m of
            Just a -> do
                mov rd fp
                add rd rd a
            Nothing -> error "erm"

    emitTo rd (Call fncl) = emitTo rd fncl

-- operands placed in r0 and r1
binop :: (CodeGen a, CodeGen b) => a -> b -> ARM UState () -> ARM UState ()
binop a b asm = do
    emitTo r0 a
    push [r0, ip]
    emitTo r1 b
    pop [r0, ip]
    asm

instance CodeGen FunctionCall where

    -- push & pop
    -- emitTo rd (FunctionCall name argv) =
    --     let x = argv `zip` [r0,r1,r2,r3]
    --     in foldr f (pure ()) x >> bl (toLabel name)
    --     where
    --         f :: (Expr, Reg) -> ARM r () -> ARM r ()
    --         f (e,r) arm = do
    --             emitTo r0 e
    --             push [r0, ip]
    --             arm
    --             pop [r, ip]

    -- sub & str
    emitTo rd (FunctionCall name argv) = do
        assert (length argv <= 4) (pure ())
        sub sp sp #16
        f argv
        pop [r0, r1, r2, r3]
        bl (toLabel name)

        where
            f :: [Expr] -> ARM UState ()
            f es = forM_ ([0..] `zip` es) $ \(n,e) -> do
                emit e
                str r0 (sp, 4*n :: Int)

addBinding :: Ident
            -> Int
            -> ARM UState ()
addBinding k off = modify (\s -> s { usBindings = e : usBindings s })
    where e = (k, off)

