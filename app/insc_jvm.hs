-- | @insc_jvm foo/bar/baz.ins@ writes @foo/bar/baz.j@ and assembles it with
-- Jasmin into @foo/bar/baz.class@.
module Main (main) where

import Control.Monad (unless)
import Data.Char (isAlpha, isAlphaNum)
import System.FilePath (replaceExtension, takeBaseName, takeDirectory, (</>))

import Compiler.Backend.JVM (compileMethod, emitJasmin)
import Compiler.Driver (Backend (..), runCompiler, runTool)

main :: IO ()
main = runCompiler Backend
  { backendExtension = ".j"
  , backendLibFile   = "jasmin.jar"
  , backendGenerate  = \output program -> do
      let className = takeBaseName output
      unless (isJavaIdentifier className) $
        Left ("file name '" ++ className ++ "' is not a valid JVM class name; rename the file")
      pure (emitJasmin className (compileMethod program))
  , backendAssemble  = \lib output ->
      runTool "JAVA" "java" ["-jar", lib </> "jasmin.jar", "-d", takeDirectory output, output]
              (replaceExtension output ".class")
  }

-- | The class is named after the file, so the name must be a Java identifier.
isJavaIdentifier :: String -> Bool
isJavaIdentifier name = case name of
  c : cs -> isStart c && all isPart cs
  [] -> False
  where
    isStart c = isAlpha c || c `elem` "_$"
    isPart c = isAlphaNum c || c `elem` "_$"
