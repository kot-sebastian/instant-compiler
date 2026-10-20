-- | Helpers over the BNFC-generated abstract syntax shared by both backends.
module Compiler.Syntax
  ( module Instant.Abs
  , BinOp (..)
  , ExpView (..)
  , view
  , isCommutative
  ) where

import Instant.Abs

data BinOp = Add | Sub | Mul | Div
  deriving (Eq, Show, Enum, Bounded)

-- | A flatter view of 'Exp' so backends handle all binary operators in one place.
data ExpView
  = Lit Integer
  | Var Ident
  | Bin BinOp Exp Exp

view :: Exp -> ExpView
view expr = case expr of
  ExpAdd a b -> Bin Add a b
  ExpSub a b -> Bin Sub a b
  ExpMul a b -> Bin Mul a b
  ExpDiv a b -> Bin Div a b
  ExpLit n   -> Lit n
  ExpVar x   -> Var x

-- | The task statement says to treat @+@ and @*@ as commutative (but not associative).
isCommutative :: BinOp -> Bool
isCommutative op = op == Add || op == Mul
