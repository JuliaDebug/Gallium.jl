# Gallium

[![Build Status](https://travis-ci.org/Keno/Gallium.jl.svg?branch=master)](https://travis-ci.org/Keno/Gallium.jl)

# Usage

For commands available at the prompt, please see the ASTInterpreter.jl README

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

To install Gallium, run the following:
```
Pkg.add("Reactive")
Pkg.checkout("Reactive")
Pkg.clone("https://github.com/Keno/ObjFileBase.jl.git")
Pkg.clone("https://github.com/Keno/StructIO.jl.git")
Pkg.clone("https://github.com/Keno/AbstractTrees.jl.git")
Pkg.clone("https://github.com/Keno/DWARF.jl.git")
Pkg.clone("https://github.com/Keno/ELF.jl.git")
Pkg.clone("https://github.com/Keno/MachO.jl.git")
Pkg.clone("https://github.com/Keno/TerminalUI.jl.git")
Pkg.clone("https://github.com/Keno/LineNumbers.jl.git")
Pkg.clone("https://github.com/Keno/ASTInterpreter.jl.git")
Pkg.clone("https://github.com/Keno/VT100.jl.git")
Pkg.clone("https://github.com/Keno/Hooking.jl.git")
Pkg.add("JuliaParser")
Pkg.checkout("JuliaParser")
Pkg.checkout("StrPack")
Pkg.clone("https://github.com/Keno/Gallium.jl.git")
```
