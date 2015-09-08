# Gallium

[![Build Status](https://travis-ci.org/Keno/Gallium.jl.svg?branch=master)](https://travis-ci.org/Keno/Gallium.jl)

For now, the easiest way to use Gallium is through the examples/call.jl script.

```julia
julia> ARGS = ["1234"]
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
```
