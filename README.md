# Gallium

[![Build Status](https://travis-ci.org/Keno/Gallium.jl.svg?branch=master)](https://travis-ci.org/Keno/Gallium.jl)

# Setting a breakpoint

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
Pkg.clone("https://github.com/Keno/JITTools.jl.git")
# Only for extra functionality by DIDebug. Not needed for normal operation
# i.e. does not need a special Cxx configuration of julia.
Pkg.clone("https://github.com/Keno/Cxx.jl.git")
Pkg.clone("https://github.com/Keno/ObjFileBase.jl.git")
Pkg.clone("https://github.com/Keno/DWARF.jl.git")
Pkg.clone("https://github.com/Keno/ELF.jl.git")
Pkg.clone("https://github.com/Keno/MachO.jl.git")
Pkg.clone("https://github.com/Keno/DIDebug.jl.git")
Pkg.clone("https://github.com/Keno/TerminalUI.jl.git")
Pkg.clone("https://github.com/Keno/Gallium.jl.git")
Pkg.clone("https://github.com/Keno/MachO.jl.git")
Pkg.clone("https://github.com/Keno/AbstractTrees.jl.git")
Pkg.clone("https://github.com/Keno/VT100.jl.git")
Pkg.clone("https://github.com/Keno/Hooking.jl.git")
# This is copied from the ASTInterpreter repository
Pkg.add("JuliaParser")
Pkg.checkout("JuliaParser", "kf/loctrack") # If this complains, try Pkg.checkout("JuliaParser") first
Pkg.clone("https://github.com/Keno/LineNumbers.jl.git")
Pkg.clone("https://github.com/Keno/ASTInterpreter.jl.git")
Pkg.checkout("StrPack")
```
