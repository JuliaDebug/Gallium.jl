# Gallium

[![Build Status](https://travis-ci.org/Keno/Gallium.jl.svg?branch=master)](https://travis-ci.org/Keno/Gallium.jl)

# Usage

**IMPORTANT**: For commands available at the prompt, please see the [ASTInterpreter.jl](https://github.com/Keno/ASTInterpreter.jl) README

## Setting a breakpoint

The main entrypoint to Gallium is the breakpoint function. E.g.
```
using Gallium
include(Pkg.dir("Gallium/examples/testprograms/misc.jl"))
Gallium.breakpoint(sinthesin,Tuple{Int64})
inaloop(2)
```

Of course you may also use ASTInterpreter directly to start debugging
without a breakpoint:
```
using Gallium
@enter gcd(5, 20)
```

## Breakpointing options
There are several different kinds of breakpoints available:
- `breakpoint(f, sig)`, e.g. `breakpoint(gcd, Tuple{Int,Int})` will set a breakpoint on entry to all methods matching the given signature.
- `breakpoint(f)` will set a breakpoint on entry to any method of `f`
- `breakpoint(file::AbstractString, line)` will set a breakpoint at line `line` in any file that contains `file` as a substring.
- `breakpoint_on_error()`. Will set a breakpoint that triggers whenever an error is thrown in julia code.

You may use `Gallium.list_breakpoints()` to list all set breakpoints, and `enable(bp), disable(bp), remove(bp)` to enable/disable or remove breakpoints.

Finally, any breakpoint can be made conditional by using the `@conditional` macro, e.g.
```
@conditional breakpoint(gcd,Tuple{Int,Int}) (a==5)
```

# Installation

To install Gallium you may simply run
```
Pkg.add("Gallium")
```

Gallium currently works on x86_64 on all three major operating systems (Mac/Linux/Windows), as well as POWER 8 (ppc64le) when using Linux.

If you wish to run the latest development version, you may also require the development version of Gallium's
dependencies. The appropriate command to move to these development versions is provided below for convencience.
However, it is **strongly** recommended that most users make use of the released version instead.
```
Pkg.clone("https://github.com/Keno/COFF.jl")
Pkg.checkout("Reactive")
Pkg.checkout("ObjFileBase")
Pkg.checkout("StructIO")
Pkg.checkout("AbstractTrees")
Pkg.checkout("DWARF")
Pkg.checkout("ELF")
Pkg.checkout("MachO")
Pkg.checkout("COFF")
Pkg.checkout("TerminalUI")
Pkg.checkout("ASTInterpreter")
Pkg.checkout("VT100")
Pkg.checkout("JuliaParser")
Pkg.checkout("Gallium")
```

# Supported Architectures and OSes

Gallium supports the X86-64 (Windows, Mac, Linux) and the POWER8 (Linux) architectures.

