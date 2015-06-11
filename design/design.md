# Gallium.jl design document

## Goals

Gallium aims to achieve a couple overall goals that guide it's design

- *Extendability*. Gallium should provide a platform to experiment with new
debugging features and schemes. In general such extension, should be
distributable as Julia packages and seamlessly integrate into the existing
setup.

- *Front-End Agnostic*. Gallium should make it easy to write new front-ends to
the core debugger functionality. If at all feasible, there should be a way to
use most features from the command line, as well as through the web, e.g. in
IJulia or Juno.

- *Multi-Language*. Since Julia heavily relies on integration with other
languages, the debugger should in general support cross-language debugging.
Initially this will mean Julia and C, but as integrations are added for other
languages, it is expected that those packages should ship plug-ins for Gallium
that allow debugging across languages.

- *Cross-Machine*. Gallium should support debugging remote machines and in
particular should easily allow debugging in a distributed multi-process setup.

- *Simple Start*. Despite aiming to provide a powerful platform, the default
experience should be simple and intuitive.

## Technologies

- *LLDB* LLDB is a debugger developed by the LLVM project. In Gallium we use
LLDB as the backend to provide the actual interaction with the system to allow
debugging processes. In general the LLDB front-end is not used, except for
debugging purposes.

- *Clang/Cxx.jl* `Cxx.jl` is used to interface with LLDB's `C++` interface as
well as being used to interpret some `Clang` data structures used internally by
LLDB (`LLDB` reconstructs a `Clang` AST from debug information). Specifically,
we do not use `LLDB`'s ScriptBridge API.

- *React.jl/Interact.jl* In order to separate the UI from the model, we make
use of `Reac.jl`'s FRP paradigm.

- *Termwin.jl* For the terminal-side implementation of the UI

## Implementation

aka the TODO list

### Working with remote data

Working with remote data can happen in many different ways. The three main axes
along which execution can be distinguished is:

- *Location*. Determines whether the code/data need to be moved before
execution. Note that in order for computation to happen code and data always
need to be available in the same process.
- *Code Origin* Which version of the AST is to be used. Since the debugger is
itself a julia process (as well as possibly having C++ headers loaded in
Cxx.jl, etc.) either the debugger's or the target's AST can be used to
interpret any given expression.
- *Codegen* Which process does the code generation. This is not necessarily the
same process as the Code Origin, if codegen is not available in the target
process. That may be the case in statically compiled julia code (either directly
or through J2C) or when experimenting with codegen.

To make clear which scheme is being used, interactive widgets that execute code,
e.g. debugging REPLs should use a standard scheme. Given that there is a
significant number of possible combinations, it is most likely not possible to
represent this using color difference as is done for the regular REPL modes.

A regular debugger such as LLDB or GDB can be interpreted as using an RRL scheme
with the remote AST recovered from debug info. Since most julia processes will
include code generation capabilities, it makes most sense to use an RRR scheme
as the default mode for Gallium.

However, there are also problems with the proposed scheme. When the memory
state of the target is corrupted (a situation which occurs frequently when
debugging), relying on the target to cooperate may be infeasible. The same
holds when the target is currently generating code, etc. However, since these
situations should only occur for more advanced users, it makes sense to adopt
the RRR scheme by default.

#### Interation between the debugger and the REPL

The debugger experience should feel very similar to the REPL experience, and in
particular to the remote REPL experience, which even though technically
available is currently not present in any reusable fashion. Ideally, the
debugger should feel essentially like a remote REPL (though attached to the
local process), and indeed in many cases it will operate quite similarly under
the hood. The primary addition of Gallium over a plain remote REPL is the
the integration of breakpointing, stepping and context extraction
functionalities.

#### RRR scheme implementation details

##### The event loop when running debugging code.

When evaluating julia code in the remote target, it is important to pay careful
attention to any possible interations with the remote event loop. One does not
in general want to run the event loop unrestrictedly as this can lead to
unpredictable behavior due to other tasks being allowed to run and modify global
variables or other global state and thus make the task of debugging significantly
more difficult. However, the event loop can also not be entirely avoided as code
run from the debugger may very well want to access I/O objects for debugging
purposes. The currently suggested solution is that the state of the task queue
and all blocked tasks be remembered unpon halting the program (and restored after
the debugging session has concluded and the user has continued the program).
However, conditions that would have woken up a blocked task probably do need to
be recorded and delivered once the program is being continued. Alternatively,
it might be desirable to create an entirely separate event loop for the duration
of the interactive debugging session, with any newly created I/O objects living
on the new event loop. In such a scheme however, it would not be possible for a
user using the debugger to cause I/O operations on already created I/O object
(e.g. to debug why a certain message does not get encoded correctly).

### Debug Info and Recompilation

In order to be able to know about the target's functions local variables, etc.
MCJIT needs to generate the requisite debug info for the target. In general, in
unoptimized code, all local variables should always be available. Anything else
should be considered a bug in LLVM and fixed there. In a lot of cases, such
debug info will also be available in the optimized version of the binary.
However, the optimizer is allowed to drop debug info when required for an
optimization. As such, it would be desirable to have a mechanism, by which
functions get recompiled to a debug version if the debugger has an interest in
them, e.g. if a breakpoint gets set therein. This recompilation should be done
by the target.

### Tracking Variable Locations (LLVM)

LLVM's debug info support allows us to track the locations of variables through
codegen and into the final binary, which gets encoded into the DWARF information
in an object file (whether actually emitted to disk when precompilation is used
or in memory during regular operations with MCJIT). The DWARF information
encodes ranges of address values for which variables are valid and in what
location to find them. Making this work effectively will most likely require
significant changes in LLVM. As a means of visualizing and performing regression
tests on the encoded information, I propose the following test setup:

Using LLVM's disassembler (via Cxx.jl) and DWARF.jl (or possibly LLVM's DWARF
parser), we can parse the range information and correlate it with the
appropriate locations in the instruction stream to obtain an output such as the
following example rendering


```julia

Function: julia_foo1234

1: var1
2: var2
3: var3


Address     Instruction  1 2 3
-------     -----------  - - -
0x00000     pushq        |
0x00000     pushq        |   x
0x00000     pushq        |   |
0x00000     pushq        | x |
0x00000     foo          | | |
0x00000     foo          | | |
0x00000     callq <bar>  x | |
0x00000     foo            | |
0x00000     foo            x |
0x00000     popq             |
0x00000     popq             |
0x00000     popq             |
0x00000     popq             |
0x00000     ret              x
```

Since the code generated by LLVM subject to continuous change, an automated
test suite should check high level features such as `variable one is alive
from function entry until the call to bar` or `variable 3 is alive at function
exit`.

### Remote/Distributed debugging

If the julia process to be debugged is not located on the local processor, some
extra care has to be taken though, given the architecutre of both LLDB and the
Julia REPL infrastructure, no major modification to the proposed scheme is
required to supported distributed debugging. The two primary scenarios in which
remote debugging could find applicability are:

1. The target is running remotely (and for some reason Gallium can not be used
remotely on the target, perhaps because it is integrated into an IDE locally) or
connecting to an embedded device that does not expose a shell.

Most of the magic here will hapen using the regular lldb/gdbserver interfaces,
since all of the application logic is implemented on the host anyway. The one
concern is how to connect Gallium and the target julia process for some of the
more deep integration, e.g. repl access to the debugger in the RRR scheme.

2. Debugging other nodes cluster nodes, as part of a multiprocessing setup.

In this case the conenction to the remote lldb/gdbserver should piggy back on
whatever communcation channel Julia uses to connect to the target. Presumably
we should extend ClusterManagers (or even better, identify the underlying
functionality we need) to be able to open new connections to the target, which
we can then reparent to the debugger.

### Terminal UI

#### Terminal Widgets
While not strictly required for debugging, the terminal interface for the
debugger will be an important part of the implementation work. In particular,
TermWin.jl needs to be extended to easily allow multiple widgets at the same
time. Further, if not already present, TermWin.jl should gain a Terminal mode
that allows multiple REPLs to be embedded side-by-side, e.g. the Julia REPL and
a debugging prompt, remote julia REPLs, etc.

#### Interact.jl

Additionally, TermWin.jl should be updated for more closer integration with
React.jl and Interact.jl. E.g.:

```julia
julia> @manipulate for i=1:10
            i * 20
       end
#========================== 1 [-----▮----] 10 ================================#
| 20                                                                          |
#=============================================================================#
```

With the widgets provided by TermWin.jl, but controlled using React/Interact.

### Initial Widgets

#### Stack Frame Widget

Simple stack frame widgets with options for showing/hiding stacks for different
language (e.g. combined view/Julia-only view). This widget should have concepts
for `active` and `highlighted` stack frames and expose signals when either of
these change.

#### Local Variable Widget

Display the value of all local variables in current stack frame. Should accept
a signal when local variables change.
