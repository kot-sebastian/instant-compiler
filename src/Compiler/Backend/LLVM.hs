-- | Code generation for LLVM IR (textual @.ll@).
--
-- Variables live in SSA registers: an assignment binds the variable to the
-- register holding the value, so no @alloca@/@load@/@store@ is needed.
module Compiler.Backend.LLVM
  ( emitLLVM
  ) where

import Control.Monad.State.Strict (State, execState, gets, modify', state)
import qualified Data.Map.Strict as Map

import Compiler.Syntax

data Operand = Reg !Int | Imm !Integer

renderOperand :: Operand -> String
renderOperand (Reg r) = '%' : show r
renderOperand (Imm n) = show n

data Gen = Gen
  { genNextReg :: !Int                       -- %0 is the unnamed entry block
  , genEnv     :: !(Map.Map Ident Operand)
  , genLines   :: [String] -> [String]       -- difference list of emitted lines
  }

type G = State Gen

emitLLVM :: Program -> String
emitLLVM (Prog stmts) = unlines $
  [ "declare void @printInt(i32)"
  , ""
  , "define i32 @main() {"
  ]
  ++ genLines (execState (mapM_ compileStmt stmts) (Gen 1 Map.empty id)) []
  ++
  [ "    ret i32 0"
  , "}"
  ]

compileStmt :: Stmt -> G ()
compileStmt stmt = case stmt of
  SAss x e -> do
    value <- compileExp e
    -- The assignment of a constant is kept as an explicit instruction: the
    -- task forbids optimising away specified operations.
    bound <- case value of
      Imm n -> define ("add i32 0, " ++ show n)
      Reg _ -> pure value
    modify' $ \g -> g { genEnv = Map.insert x bound (genEnv g) }
  SExp e -> do
    value <- compileExp e
    emit ("call void @printInt(i32 " ++ renderOperand value ++ ")")

compileExp :: Exp -> G Operand
compileExp e = case view e of
  Lit n -> pure (Imm n)
  -- The frontend guarantees every variable is assigned before use.
  Var x -> gets ((Map.! x) . genEnv)
  Bin op a b -> do
    va <- compileExp a
    vb <- compileExp b
    define (opName op ++ " i32 " ++ renderOperand va ++ ", " ++ renderOperand vb)
  where
    opName op = case op of
      Add -> "add"
      Sub -> "sub"
      Mul -> "mul"
      Div -> "sdiv"

-- | Emit @%N = rhs@ into a fresh register and return it.
define :: String -> G Operand
define rhs = do
  reg <- state $ \g -> (Reg (genNextReg g), g { genNextReg = genNextReg g + 1 })
  emit (renderOperand reg ++ " = " ++ rhs)
  pure reg

emit :: String -> G ()
emit line = modify' $ \g -> g { genLines = genLines g . (("    " ++ line) :) }
