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
Pkg.add("Gallium")
Pkg.checkout("Reactive")
Pkg.checkout("JuliaParser")
Pkg.checkout("StrPack")
```
