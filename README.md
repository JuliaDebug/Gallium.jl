# Gallium

[![Build Status](https://travis-ci.org/Keno/Gallium.jl.svg?branch=master)](https://travis-ci.org/Keno/Gallium.jl)

For now, the easiest way to use Gallium is through the examples/call.jl script.

```julia
julia> ARGS = ["1234"]  # PID of the Julia process you wish to control
julia> include("call.jl")
```

This will add several REPL modes:
- Global target julia mode (activated via `\ `). Evaluate julia code at global scope in the inferior
- Host C++ mode (activated via `<`). Evaluate C++ code in the host. Useful to interact with LLDB's C++ API
- Target C++ mode (activated via `>`). Evaluate C++ code in the target
- LLDB mode (activated via ``` ` ```). Run an lldb command

The LLDB command prompt supports all your usual debugger commands (`b`, `bt`, `s`, `n`, `finish`), as well as the following custom commands:
- `js` - Step through julia code. Including stepping through indirect dispatch
- `jbt` - Obtain a julia backtrace
- `jp` - Run a julia expression, with current local variables in scope (to be integrated into the target julia REPL mode)
- `jobj` - Retrieve a handle to the current frame's JIT object file

# Debugging missing local variable and line number coverage

Local variable coverage can be missing at several level: julia, llvm or DWARF. To debug at the julia level, just use code_typed, etc. To debug at the llvm level, the following command sequence may be helpful:

```
julia> using DIDebug
julia> first(current_thread(Gallium.ctx(dbg))) |> Gallium.getASTForFrame
Target C++> $ans->functionObject
Target C++> GetBitcodeForFunction($ans)
julia> data = Gallium.retrieve(dbg,ans)
julia> DIDebug.parseBitcode(data)
C++> $ans->dump()
```

To debug at the DWARF, level the following may be helpful:

```
LLDB> jobj
julia> oh = ans
julia> collect(DWARF.DIETrees(ObjFileBase.debugsections(oh)))
```

# Building Gallium

Gallium requires custom versions of julia, LLVM, Clang, LLDB and libuv. The easiest way to obtain these
is to checkout the kf/gallium branch of julia, which will attempt to check out the correct branches and
build everything from scratch. Note that this only works on a fresh install.

Alternatively, if you already have a version of llvm-svn checked out, you can manually go in and
check out the kf/gallium branch on JuliaLang/{llvm, clang, lldb} and rebuild each of them.

After one of these two methods of building Julia with support for Gallium suceeds, you may need to apply
the following patch to Cxx.jl:

```
diff --git a/src/bootstrap.cpp b/src/bootstrap.cpp
index 01ff792..8dca780 100644
--- a/src/bootstrap.cpp
+++ b/src/bootstrap.cpp
@@ -846,8 +846,8 @@ DLLEXPORT void init_clang_instance(C, const char *Triple) {
     Cxx->CI->getLangOpts().Bool = 1;
     Cxx->CI->getLangOpts().WChar = 1;
     Cxx->CI->getLangOpts().C99 = 1;
-    Cxx->CI->getLangOpts().RTTI = 1;
-    Cxx->CI->getLangOpts().RTTIData = 1;
+    Cxx->CI->getLangOpts().RTTI = 0;
+    Cxx->CI->getLangOpts().RTTIData = 0;
     Cxx->CI->getLangOpts().ImplicitInt = 0;
     Cxx->CI->getLangOpts().PICLevel = 2;
     Cxx->CI->getLangOpts().Exceptions = 1;          // exception handling
```
Finally, you'll need to run the following series of commands at the julia prompt:
```
Pkg.clone("https://github.com/Keno/Cxx.jl.git")
Pkg.build("Cxx")
Pkg.clone("Reactive")
Pkg.clone("https://github.com/Keno/JITTools.jl.git")
Pkg.clone("https://github.com/Keno/DIDebug.jl.git")
Pkg.clone("https://github.com/Keno/TerminalUI.jl.git")
Pkg.clone("https://github.com/Keno/Gallium.jl.git")
Pkg.clone("https://github.com/Keno/ObjFileBase.jl.git")
Pkg.clone("https://github.com/Keno/MachO.jl.git")
Pkg.clone("https://github.com/Keno/ELF.jl.git")
Pkg.clone("https://github.com/Keno/AbstractTrees.jl.git")
Pkg.clone("https://github.com/Keno/VT100.jl.git")
```

# Common Troubles

- `unable to connect` on Linux: Make sure ptrace protection is disabled. You can do this manually by running `echo 0 > /proc/sys/kernel/yama/ptrace_scope` Make sure that you are connecting to a valid PID of a running Julia process (see `ARGS` setting above).

