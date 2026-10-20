-- | Code generation for the JVM (Jasmin assembler syntax).
--
-- Expressions are compiled with the Sethi–Ullman strategy: for every binary
-- operator the operand needing the deeper stack is evaluated first, which
-- minimises the declared @.limit stack@. When this reorders a non-commutative
-- operator a single @swap@ restores the operand order.
module Compiler.Backend.JVM
  ( Instr (..)
  , Method (..)
  , compileMethod
  , renderInstr
  , emitJasmin
  ) where

import qualified Data.List as List
import qualified Data.Map.Strict as Map

import Compiler.Syntax

data Instr
  = IConst !Integer
  | ILoad !Int
  | IStore !Int
  | IArith !BinOp
  | ISwap
  | GetStdout   -- ^ push @System.out@
  | PrintlnInt  -- ^ @System.out.println(int)@
  deriving (Eq, Show)

-- | Body of @main@ together with the limits Jasmin needs.
data Method = Method
  { methodStack  :: !Int
  , methodLocals :: !Int
  , methodCode   :: [Instr]
  } deriving (Eq, Show)

-- | Difference list: O(1) append, so code generation stays linear even for
-- very deep expressions.
type Code = [Instr] -> [Instr]

type Locals = Map.Map Ident Int

data Acc = Acc
  { accLocals    :: !Locals
  , accNextLocal :: !Int     -- slot 0 holds @String[] args@
  , accStack     :: !Int
  , accCode      :: Code
  }

compileMethod :: Program -> Method
compileMethod (Prog stmts) = finish (List.foldl' step (Acc Map.empty 1 0 id) stmts)
  where
    finish acc = Method (accStack acc) (accNextLocal acc) (accCode acc [])

    step acc stmt = case stmt of
      SAss x e ->
        let (depth, code) = compileExp (accLocals acc) e
            slot = Map.findWithDefault (accNextLocal acc) x (accLocals acc)
            isNew = slot == accNextLocal acc
        in acc { accLocals    = if isNew then Map.insert x slot (accLocals acc) else accLocals acc
               , accNextLocal = if isNew then slot + 1 else accNextLocal acc
               , accStack     = max (accStack acc) depth
               , accCode      = accCode acc . code . (IStore slot :)
               }
      SExp e ->
        let (depth, code) = printExp (compileExp (accLocals acc) e)
        in acc { accStack = max (accStack acc) depth
               , accCode  = accCode acc . code
               }

-- | Returns the stack depth the expression needs together with its code.
compileExp :: Locals -> Exp -> (Int, Code)
compileExp locals = go
  where
    go e = case view e of
      Lit n -> (1, (IConst n :))
      -- The frontend guarantees every variable is assigned before use.
      Var x -> (1, (ILoad (locals Map.! x) :))
      Bin op a b
        | da >= db  -> (max da (db + 1), ca . cb . (IArith op :))
        | otherwise -> (max db (da + 1), cb . ca . swapFor op . (IArith op :))
        where
          (da, ca) = go a
          (db, cb) = go b

    swapFor op
      | isCommutative op = id
      | otherwise        = (ISwap :)

-- | Wrap an expression in @println@. A single-slot expression is pushed after
-- @System.out@ (depth 2, no swap); deeper ones are evaluated first and swapped
-- under the stream, so printing never needs more stack than the expression.
printExp :: (Int, Code) -> (Int, Code)
printExp (depth, code)
  | depth <= 1 = (2, (GetStdout :) . code . (PrintlnInt :))
  | otherwise  = (depth, code . (GetStdout :) . (ISwap :) . (PrintlnInt :))

-- | Picks the shortest encoding for constants and local-variable slots.
renderInstr :: Instr -> String
renderInstr instr = case instr of
  IConst n
    | n == -1                -> "iconst_m1"
    | 0 <= n && n <= 5       -> "iconst_" ++ show n
    | fitsSigned 8 n         -> "bipush " ++ show n
    | fitsSigned 16 n        -> "sipush " ++ show n
    | otherwise              -> "ldc " ++ show n
  ILoad slot  -> withSlot "iload" slot
  IStore slot -> withSlot "istore" slot
  IArith op   -> case op of
    Add -> "iadd"
    Sub -> "isub"
    Mul -> "imul"
    Div -> "idiv"
  ISwap      -> "swap"
  GetStdout  -> "getstatic java/lang/System/out Ljava/io/PrintStream;"
  PrintlnInt -> "invokevirtual java/io/PrintStream/println(I)V"
  where
    withSlot name slot
      | slot <= 3 = name ++ "_" ++ show slot
      | otherwise = name ++ " " ++ show slot
    fitsSigned bits n = let bound = 2 ^ (bits - 1 :: Int) in -bound <= n && n < bound

-- | Full Jasmin source of a class whose @main@ runs the program. The class
-- name is quoted so file names that are Jasmin keywords (e.g. @locals.ins@)
-- or contain characters such as @-@ still assemble.
emitJasmin :: String -> Method -> String
emitJasmin className method = unlines $
  [ ".class public '" ++ className ++ "'"
  , ".super java/lang/Object"
  , ""
  , ".method public <init>()V"
  , "    aload_0"
  , "    invokespecial java/lang/Object/<init>()V"
  , "    return"
  , ".end method"
  , ""
  , ".method public static main([Ljava/lang/String;)V"
  , "    .limit stack " ++ show (methodStack method)
  , "    .limit locals " ++ show (methodLocals method)
  ]
  ++ map (("    " ++) . renderInstr) (methodCode method)
  ++
  [ "    return"
  , ".end method"
  ]
