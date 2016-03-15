# Gallium

[![Build Status](https://travis-ci.org/Keno/Gallium.jl.svg?branch=master)](https://travis-ci.org/Keno/Gallium.jl)

To install Gallium, run the following:
```
Pkg.add("Reactive")
Pkg.checkout("Reactive")
Pkg.clone("https://github.com/Keno/JITTools.jl.git")
Pkg.clone("https://github.com/Keno/DIDebug.jl.git")
Pkg.clone("https://github.com/Keno/TerminalUI.jl.git")
Pkg.clone("https://github.com/Keno/Gallium.jl.git")
Pkg.clone("https://github.com/Keno/ObjFileBase.jl.git")
Pkg.clone("https://github.com/Keno/MachO.jl.git")
Pkg.clone("https://github.com/Keno/ELF.jl.git")
Pkg.clone("https://github.com/Keno/AbstractTrees.jl.git")
Pkg.clone("https://github.com/Keno/VT100.jl.git")
# This is copied from the ASTInterpreter repository
Pkg.add("JuliaParser")
Pkg.checkout("JuliaParser", "kf/loctrack") # If this complains, try Pkg.checkout("JuliaParser") first
Pkg.clone("https://github.com/Keno/LineNumbers.jl.git")
Pkg.clone("https://github.com/Keno/ASTInterpreter.jl.git")
```
