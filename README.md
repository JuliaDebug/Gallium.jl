# Gallium

This is the julia debugger. Please note that the 0.6 version of this package
currently does not support breakpointing, C/C++ debugging or native code
inspection. These features are being rebuilt, but were never particularly
reliable in prior versions of this package and a cause of instability for
the more mature features. In exchange, this package features a signficantly
more robust pure julia debug prompt, provided by [ASTInterpreter2](https://github.com/Keno/ASTInterpreter2.jl). Please file interpreter issues against that package.

# Usage

```
using Gallium
@enter gcd(10, 20)
```

Type `help` at the debug prompt to see a list of available commands.
