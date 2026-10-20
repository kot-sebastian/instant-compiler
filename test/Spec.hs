-- | Unit and property tests that need neither Java nor LLVM installed.
--
-- Generated code is checked against a reference interpreter by executing it
-- with small simulators: a JVM operand-stack machine for 'Instr' and an
-- interpreter of the (very regular) LLVM IR emitted by the LLVM backend.
module Main (main) where

import Control.Monad (foldM, unless, when)
import Data.Int (Int32)
import Data.List (isInfixOf, stripPrefix)
import qualified Data.Map.Strict as Map
import System.Exit (exitFailure)
import Test.QuickCheck

import Compiler.Backend.JVM
import Compiler.Backend.LLVM (emitLLVM)
import Compiler.Frontend
import Compiler.Syntax

main :: IO ()
main = do
  unitOk <- and <$> mapM runUnit unitTests
  propOk <- and <$> mapM runProp properties
  unless (unitOk && propOk) exitFailure

-- * Reference semantics

type Outcome = Either String [Int32]

-- | 32-bit wrap-around arithmetic, division truncating towards zero
-- (the semantics of both @idiv@ and @sdiv@).
arith :: BinOp -> Int32 -> Int32 -> Either String Int32
arith op a b = case op of
  Add -> Right (a + b)
  Sub -> Right (a - b)
  Mul -> Right (a * b)
  Div
    | b == 0    -> Left "division by zero"
    | b == -1   -> Right (negate a)  -- avoids Haskell's overflow exception for minBound
    | otherwise -> Right (a `quot` b)

evalProgram :: Program -> Outcome
evalProgram (Prog stmts) = reverse . snd <$> foldM step (Map.empty, []) stmts
  where
    step (env, out) (SAss x e) = (\v -> (Map.insert x v env, out)) <$> evalExp env e
    step (env, out) (SExp e)   = (\v -> (env, v : out)) <$> evalExp env e
    evalExp env e = case view e of
      Lit n -> Right (fromInteger n)
      Var x -> maybe (Left "undefined variable") Right (Map.lookup x env)
      Bin op a b -> do
        va <- evalExp env a
        vb <- evalExp env b
        arith op va vb

-- * JVM simulator

data Slot = IntVal Int32 | PrintStream
  deriving (Eq, Show)

-- | Runs a method; returns the printed values and the highest stack depth
-- reached, or an error for ill-typed code / division by zero.
runJvm :: Method -> Either String ([Int32], Int)
runJvm method = finish =<< foldM exec ([], Map.empty, [], 0) (methodCode method)
  where
    finish (stack, _, out, peak)
      | null stack = Right (reverse out, peak)
      | otherwise  = Left ("stack not empty at return: " ++ show stack)

    exec (stack, locals, out, peak) instr = do
      (stack', locals', out') <- step instr stack locals out
      when (length stack' > methodStack method) $
        Left ("stack overflow at " ++ show instr)
      pure (stack', locals', out', max peak (length stack'))

    step instr stack locals out = case (instr, stack) of
      (IConst n, _)                  -> Right (IntVal (fromInteger n) : stack, locals, out)
      (ILoad i, _)                   -> do
        checkSlot i
        v <- maybe (Left ("uninitialised local " ++ show i)) Right (Map.lookup i locals)
        Right (IntVal v : stack, locals, out)
      (IStore i, IntVal v : rest)    -> checkSlot i >> Right (rest, Map.insert i v locals, out)
      (IArith op, IntVal b : IntVal a : rest) -> do
        v <- arith op a b
        Right (IntVal v : rest, locals, out)
      (ISwap, x : y : rest)          -> Right (y : x : rest, locals, out)
      (GetStdout, _)                 -> Right (PrintStream : stack, locals, out)
      (PrintlnInt, IntVal v : PrintStream : rest) -> Right (rest, locals, v : out)
      _ -> Left ("bad stack for " ++ show instr ++ ": " ++ show stack)

    checkSlot i =
      unless (1 <= i && i < methodLocals method) $ Left ("local slot out of range: " ++ show i)

-- * LLVM IR interpreter (only for the subset our backend emits)

runLlvm :: String -> Either String [Int32]
runLlvm ir = do
  body <- extractBody (lines ir)
  (_, _, out) <- foldM exec (Map.empty, 1 :: Int, []) body
  Right (reverse out)
  where
    extractBody ls = case break (== "define i32 @main() {") ls of
      (_, _ : rest) -> case reverse rest of
        "}" : "    ret i32 0" : revBody -> Right (map (dropWhile (== ' ')) (reverse revBody))
        _ -> Left "unexpected function epilogue"
      _ -> Left "missing main"

    exec (regs, next, out) line = case words line of
      [dst, "=", opName, "i32", a, b] -> do
        reg <- maybe (Left ("bad register " ++ dst)) Right (stripPrefix "%" dst)
        unless (reg == show next) $ Left ("registers not sequential at " ++ line)
        op <- maybe (Left ("unknown op " ++ opName)) Right (lookup opName ops)
        va <- operand regs (init a)  -- drop the trailing comma
        vb <- operand regs b
        v <- arith op va vb
        Right (Map.insert dst v regs, next + 1, out)
      ["call", "void", "@printInt(i32", arg] -> do
        v <- operand regs (init arg)  -- drop the closing parenthesis
        Right (regs, next, v : out)
      _ -> Left ("unexpected line: " ++ line)

    ops = [("add", Add), ("sub", Sub), ("mul", Mul), ("sdiv", Div)]
    operand regs s@('%' : _) = maybe (Left ("use before def " ++ s)) Right (Map.lookup s regs)
    operand _ s = case reads s of
      [(n, "")] -> Right (fromInteger n)
      _ -> Left ("bad operand " ++ s)

-- * Random programs (every variable is assigned before use)

newtype Valid = Valid Program

instance Show Valid where
  show (Valid (Prog stmts)) = unlines (map showStmt stmts)
    where
      showStmt (SAss (Ident x) e) = x ++ " = " ++ showExp e ++ ";"
      showStmt (SExp e) = showExp e ++ ";"
      showExp e = case view e of
        Lit n -> show n
        Var (Ident x) -> x
        Bin op a b -> "(" ++ showExp a ++ [' ', symbol op, ' '] ++ showExp b ++ ")"
      symbol op = case op of Add -> '+'; Sub -> '-'; Mul -> '*'; Div -> '/'

instance Arbitrary Valid where
  arbitrary = Valid . Prog <$> sized (\n -> choose (0, 1 + n `div` 5) >>= go [])
    where
      go _ 0 = pure []
      go defined k = do
        stmt <- frequency
          [ (2, SAss <$> elements varNames <*> genExp defined)
          , (1, SExp <$> genExp defined)
          ]
        let defined' = case stmt of
              SAss x _ -> x : defined
              SExp _ -> defined
        (stmt :) <$> go defined' (k - 1 :: Int)

      varNames = map (Ident . pure) "abcdefgh"  -- more than 4 → exercises iload/istore N

      genExp defined = sized (go' . min 8)
        where
          go' 0 = leaf
          go' n = frequency
            [ (1, leaf)
            , (3, do op <- elements [minBound .. maxBound]
                     l <- choose (0, n - 1)
                     r <- choose (0, n - 1)
                     a <- go' l
                     b <- go' r
                     pure (binary op a b))
            ]
          leaf = frequency $
            [ (3, ExpLit <$> choose (0, 7))
            , (1, ExpLit <$> elements [127, 128, 32767, 32768, 2147483647])
            ] ++ [ (3, ExpVar <$> elements defined) | not (null defined) ]

      binary op = case op of Add -> ExpAdd; Sub -> ExpSub; Mul -> ExpMul; Div -> ExpDiv

-- | Optimal JVM stack depth computed independently of the backend:
-- minimum over both evaluation orders of each operator.
optimalDepth :: Exp -> Int
optimalDepth e = case view e of
  Bin _ a b -> let da = optimalDepth a; db = optimalDepth b
               in min (max da (db + 1)) (max db (da + 1))
  _ -> 1

properties :: [(String, Property)]
properties =
  [ ("JVM code computes the reference result", property $ \(Valid p) ->
      case (evalProgram p, runJvm (compileMethod p)) of
        (Right expected, Right (actual, _)) -> actual === expected
        (Left _, Left err) -> counterexample err ("division by zero" `isInfixOf` err)
        (expected, actual) -> counterexample (show expected ++ " /= " ++ show actual) False)
  , ("JVM .limit stack is exact (safe and tight)", property $ \(Valid p) ->
      case runJvm (compileMethod p) of
        Right (_, peak) -> methodStack (compileMethod p) === peak
        Left _ -> property Discard)
  , ("JVM .limit stack is optimal", property $ \(Valid p@(Prog stmts)) ->
      methodStack (compileMethod p) === maximum (0 : map stmtDepth stmts))
  , ("JVM .limit locals = 1 + number of variables", property $ \(Valid p@(Prog stmts)) ->
      methodLocals (compileMethod p)
        === 1 + Map.size (Map.fromList [ (x, ()) | SAss x _ <- stmts ]))
  , ("LLVM code computes the reference result", property $ \(Valid p) ->
      case (evalProgram p, runLlvm (emitLLVM p)) of
        (Right expected, actual) -> actual === Right expected
        (Left _, _) -> property Discard)  -- sdiv by zero is undefined behaviour in LLVM
  , ("frontend accepts generated programs", property $ \(Valid p) ->
      checkProgram p === Right ())
  ]
  where
    stmtDepth (SAss _ e) = optimalDepth e
    stmtDepth (SExp e) = max 2 (optimalDepth e)  -- System.out + value

runProp :: (String, Property) -> IO Bool
runProp (name, prop) = do
  putStr ("property: " ++ name ++ " ... ")
  result <- quickCheckWithResult stdArgs { maxSuccess = 500, maxSize = 40, chatty = False } prop
  putStrLn (output result)
  pure (isSuccess result)

-- * Unit tests

unitTests :: [(String, Bool)]
unitTests =
  [ ("addition is right-associative", parsed "1 + 2 + 3" == Right (ExpAdd (lit 1) (ExpAdd (lit 2) (lit 3))))
  , ("subtraction is left-associative", runs "1 - 2 - 3" == Right [-4])
  , ("division is left-associative", runs "16 / 4 / 2" == Right [2])
  , ("multiplication binds tighter", runs "2 + 3 * 4" == Right [14])
  , ("parentheses", runs "(2 + 3) * 4" == Right [20])
  , ("assignment and use", runs "x = 5; y = x * x; y - x" == Right [20])
  , ("empty program", runs "" == Right [])
  , ("parse error is reported", isParseError (frontend "x = ;"))
  , ("undefined variable is rejected", frontend "x = y + 1" == Left (UndefinedVariable 1 (Ident "y")))
  , ("self-referencing first assignment is rejected", frontend "a = 1; x = x" == Left (UndefinedVariable 2 (Ident "x")))
  , ("literal above 2^31-1 is rejected", frontend "2147483648" == Left (LiteralOutOfRange 1 2147483648))
  , ("largest int literal is accepted", runs "2147483647" == Right [2147483647])
  , ("iconst for 0..5", map (renderInstr . IConst) [0, 5] == ["iconst_0", "iconst_5"])
  , ("bipush for 6..127", map (renderInstr . IConst) [6, 127] == ["bipush 6", "bipush 127"])
  , ("sipush for 128..32767", map (renderInstr . IConst) [128, 32767] == ["sipush 128", "sipush 32767"])
  , ("ldc above 32767", renderInstr (IConst 32768) == "ldc 32768")
  , ("iload_/istore_ for slots 0..3", map renderInstr [ILoad 3, IStore 1] == ["iload_3", "istore_1"])
  , ("iload/istore for slots >= 4", map renderInstr [ILoad 4, IStore 9] == ["iload 4", "istore 9"])
  , ("no swap for commutative operators", ISwap `notElem` codeOf "x = 1 + (2 * 3); y = 4 * (x + 5)")
  , ("swap for reordered subtraction", codeOf "1 - (2 - 3)"
      == [IConst 2, IConst 3, IArith Sub, IConst 1, ISwap, IArith Sub, GetStdout, ISwap, PrintlnInt])
  , ("println of a single value needs no swap", codeOf "7" == [GetStdout, IConst 7, PrintlnInt])
  , ("LLVM output", fmap emitLLVM (frontend "x = 2; x / 3") == Right (unlines
      [ "declare void @printInt(i32)"
      , ""
      , "define i32 @main() {"
      , "    %1 = add i32 0, 2"
      , "    %2 = sdiv i32 %1, 3"
      , "    call void @printInt(i32 %2)"
      , "    ret i32 0"
      , "}"
      ]))
  ]
  where
    lit = ExpLit
    parsed src = case frontend src of
      Right (Prog [SExp e]) -> Right e
      other -> Left (show other)
    runs src = either (Left . show) evalProgram (frontend src)
    codeOf src = either (const []) (methodCode . compileMethod) (frontend src)
    isParseError (Left (ParseError _)) = True
    isParseError _ = False

runUnit :: (String, Bool) -> IO Bool
runUnit (name, ok) = do
  putStrLn ((if ok then "ok      " else "FAILED  ") ++ name)
  pure ok
