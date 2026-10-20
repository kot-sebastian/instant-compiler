-- | Parsing and static checks shared by both compilers.
module Compiler.Frontend
  ( CompileError (..)
  , renderError
  , frontend
  , parseProgram
  , checkProgram
  ) where

import qualified Data.Set as Set

import Compiler.Syntax
import Instant.Par (myLexer, pProgram)

data CompileError
  = ParseError String
  | UndefinedVariable Int Ident      -- ^ statement number (1-based), variable
  | LiteralOutOfRange Int Integer    -- ^ statement number (1-based), literal
  deriving (Eq, Show)

renderError :: CompileError -> String
renderError err = case err of
  ParseError msg -> "parse error: " ++ msg
  UndefinedVariable n (Ident x) ->
    "statement " ++ show n ++ ": variable '" ++ x ++ "' is used before being assigned"
  LiteralOutOfRange n v ->
    "statement " ++ show n ++ ": integer literal " ++ show v
      ++ " does not fit in a 32-bit int (max " ++ show maxInt32 ++ ")"

-- | Parse and validate a program. A program accepted here can be compiled by
-- every backend without further checks.
frontend :: String -> Either CompileError Program
frontend source = do
  program <- parseProgram source
  checkProgram program
  pure program

parseProgram :: String -> Either CompileError Program
parseProgram = either (Left . ParseError) Right . pProgram . myLexer

-- | Every variable must be assigned before it is read, and every literal must
-- fit in a JVM/LLVM @i32@.
checkProgram :: Program -> Either CompileError ()
checkProgram (Prog stmts) = go Set.empty (zip [1 ..] stmts)
  where
    go _ [] = Right ()
    go defined ((n, stmt) : rest) = case stmt of
      SAss x e -> checkExp n defined e >> go (Set.insert x defined) rest
      SExp e   -> checkExp n defined e >> go defined rest

checkExp :: Int -> Set.Set Ident -> Exp -> Either CompileError ()
checkExp n defined = go
  where
    go e = case view e of
      Lit v
        | v > maxInt32 -> Left (LiteralOutOfRange n v)
        | otherwise    -> Right ()
      Var x
        | x `Set.member` defined -> Right ()
        | otherwise              -> Left (UndefinedVariable n x)
      Bin _ a b -> go a >> go b

maxInt32 :: Integer
maxInt32 = 2 ^ (31 :: Int) - 1
