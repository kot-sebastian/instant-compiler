{-# LANGUAGE ScopedTypeVariables #-}

-- | Command-line driver shared by @insc_jvm@ and @insc_llvm@.
module Compiler.Driver
  ( Backend (..)
  , runCompiler
  , runTool
  ) where

import Control.Exception (IOException, evaluate, try)
import Control.Monad (filterM, unless, when)
import Control.Monad.Except (ExceptT, runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.List (partition)
import Data.Maybe (fromMaybe)
import System.Directory (doesFileExist, removeFile)
import System.Environment (getArgs, getExecutablePath, getProgName, lookupEnv)
import System.Exit (ExitCode (..), exitFailure, exitSuccess)
import System.FilePath (replaceExtension, takeDirectory, (</>))
import System.IO (hPutStr, hPutStrLn, stderr)
import System.Process (readProcessWithExitCode)

import Compiler.Frontend (frontend, renderError)
import Compiler.Syntax (Program)
import Paths_instant (getDataDir)

data Backend = Backend
  { backendExtension :: String
    -- ^ extension of the generated source, e.g. @.j@
  , backendLibFile   :: FilePath
    -- ^ file that must exist in the @lib@ directory (used to locate it)
  , backendGenerate  :: FilePath -> Program -> Either String String
    -- ^ generated-file path → program → generated source
  , backendAssemble  :: FilePath -> FilePath -> ExceptT String IO ()
    -- ^ lib directory → generated file → produce the final artefact
  }

type Compile = ExceptT String IO

runCompiler :: Backend -> IO ()
runCompiler backend = do
  prog <- getProgName
  (flags, files) <- partition isFlag <$> getArgs
  let failWith msg = hPutStr stderr msg >> exitFailure
  when (any (`elem` ["-h", "--help"]) flags) $ putStr (usage prog) >> exitSuccess
  case filter (/= "--emit-only") flags of
    unknown : _ -> failWith (prog ++ ": unknown option " ++ unknown ++ "\n\n" ++ usage prog)
    [] | null files -> failWith (usage prog)
       | otherwise  -> do
           let emitOnly = "--emit-only" `elem` flags
           results <- mapM (compileFile backend emitOnly) files
           unless (and results) exitFailure
  where
    isFlag arg = take 1 arg == "-" && arg /= "-"

usage :: String -> String
usage prog = unlines
  [ "Usage: " ++ prog ++ " [--emit-only] FILE.ins..."
  , ""
  , "Compiles each Instant program FILE.ins next to the input file."
  , ""
  , "  --emit-only  only write the generated source, do not run external tools"
  , "  -h, --help   show this help"
  , ""
  , "Environment: INSTANT_LIB_DIR (directory with jasmin.jar / runtime.bc),"
  , "             JAVA, LLVM_LINK (override tool executables)."
  ]

-- | Compile a single file; errors are reported on stderr and yield 'False'.
compileFile :: Backend -> Bool -> FilePath -> IO Bool
compileFile backend emitOnly input = do
  result <- runExceptT $ do
    source <- io ("cannot read " ++ input) (readFile input >>= \s -> evaluate (length s) >> pure s)
    program <- either (throwError . renderError) pure (frontend source)
    let output = replaceExtension input (backendExtension backend)
    when (output == input) $ throwError "input would be overwritten by the generated file"
    code <- either throwError pure (backendGenerate backend output program)
    io ("cannot write " ++ output) (writeFile output code)
    unless emitOnly $ do
      libDir <- findLibDir (backendLibFile backend)
      backendAssemble backend libDir output
  case result of
    Left err -> hPutStrLn stderr (input ++ ": " ++ err) >> pure False
    Right () -> pure True

io :: String -> IO a -> Compile a
io context action = do
  r <- liftIO (try action)
  case r of
    Left (e :: IOException) -> throwError (context ++ ": " ++ show e)
    Right a -> pure a

-- | Run an external program that must create @artefact@; its output is only
-- shown on failure. The artefact is checked explicitly because Jasmin exits
-- with code 0 even when assembly fails.
runTool :: String -> FilePath -> [String] -> FilePath -> Compile ()
runTool envVar defaultExe args artefact = do
  exe <- liftIO (fromMaybe defaultExe <$> lookupEnv envVar)
  io ("cannot remove stale " ++ artefact) $
    doesFileExist artefact >>= \stale -> when stale (removeFile artefact)
  (code, out, err) <- io ("cannot run " ++ exe) (readProcessWithExitCode exe args "")
  created <- liftIO (doesFileExist artefact)
  unless (code == ExitSuccess && created) $
    throwError (unwords (exe : args) ++ " failed (" ++ reason code ++ "):\n" ++ out ++ err)
  where
    reason (ExitFailure c) = "exit code " ++ show c
    reason ExitSuccess = artefact ++ " was not created"

-- | Locate the directory with the runtime files. Searched in order:
-- @$INSTANT_LIB_DIR@, @lib@ next to the executable (layout after @make@),
-- the installed cabal data directory, and @lib@ in the working directory.
findLibDir :: FilePath -> Compile FilePath
findLibDir marker = do
  override <- liftIO (lookupEnv "INSTANT_LIB_DIR")
  exeDir <- liftIO (takeDirectory <$> getExecutablePath)
  dataDir <- liftIO (getDataDir `orElse` pure "")
  let candidates = maybe [] pure override
        ++ [exeDir </> "lib", dataDir </> "lib", "lib"]
  found <- liftIO (filterM (doesFileExist . (</> marker)) candidates)
  case found of
    dir : _ -> pure dir
    [] -> throwError ("cannot find " ++ marker ++ "; looked in: " ++ unwords candidates
                      ++ " (set INSTANT_LIB_DIR to the project's lib directory)")
  where
    orElse action fallback = try action >>= either (\(_ :: IOException) -> fallback) pure
