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

# Installation

To install Gallium you may simply run
```
Pkg.add("Gallium")
```
If you wish to run the latest development version, you may also require the development version of Gallium's
dependencies. The appropriate command to move to these development versions is provided below for convencience.
However, it is **strongly** recommended that most users make use of the released version instead.
```
Pkg.checkout("Reactive")
Pkg.checkout("ObjFileBase")
Pkg.checkout("StructIO")
Pkg.checkout("AbstractTrees")
Pkg.checkout("DWARF")
Pkg.checkout("ELF")
Pkg.checkout("MachO")
Pkg.checkout("TerminalUI")
Pkg.checkout("ASTInterpreter")
Pkg.checkout("VT100")
Pkg.checkout("JuliaParser")
Pkg.checkout("Gallium")
```
