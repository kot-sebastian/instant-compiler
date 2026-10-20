-- | @insc_llvm foo/bar/baz.ins@ writes @foo/bar/baz.ll@ and links it with the
-- runtime (@printInt@) into @foo/bar/baz.bc@, runnable with @lli@.
module Main (main) where

import System.FilePath (replaceExtension, (</>))

import Compiler.Backend.LLVM (emitLLVM)
import Compiler.Driver (Backend (..), runCompiler, runTool)

main :: IO ()
main = runCompiler Backend
  { backendExtension = ".ll"
  , backendLibFile   = "runtime.bc"
  , backendGenerate  = \_ -> Right . emitLLVM
  , backendAssemble  = \lib output ->
      -- llvm-link reads textual IR directly, so no separate llvm-as step is needed.
      let bitcode = replaceExtension output ".bc"
      in runTool "LLVM_LINK" "llvm-link" ["-o", bitcode, output, lib </> "runtime.bc"] bitcode
  }
