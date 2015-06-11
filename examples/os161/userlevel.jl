include("common.jl")

cxx"""
#include "lldb/Target/Process.h"
#include "lldb/lldb-enumerations.h"
#include "/Users/kfischer/julia/deps/llvm-svn/tools/lldb/source/Plugins/Process/Utility/RegisterContextMemory.h"
#include "/Users/kfischer/julia/deps/llvm-svn/tools/lldb/source/Plugins/Process/Utility/ThreadMemory.h"
"""

lldb_exec(dbg,"log enable lldb")

tlist = icxx"$target->m_process_sp->GetThreadList();"
process = icxx"$target->m_process_sp.get();";
thread = tlist[0]
reg_ctx = icxx"$thread->GetRegisterContext().get();"
tf=0x80193f68

mreg_ctx = icxx"""
new RegisterContextMemory(*$thread,0,$reg_ctx,$tf,38*sizeof(uint32_t));
"""

thread = icxx"""
auto T2 = new ThreadMemory (*$process,
                  0x20,
                  "user level",
                  "",
                  $tf);
T2->SetRegisterContext($mreg_ctx);
return T2;
"""
#=
TSP = icxx" lldb::ThreadSP T($thread); return T; "
icxx" $thread->GetStatus (*$dbg->GetOutputFile().get(),0,10,0); ";

=#

icxx"""
lldb_private::RegisterValue reg_value;
reg_value.SetType(lldb::eRegisterValueGCC);
$mreg_ctx->ReadRegister($(mreg_ctx[29]),reg_value);
"""

data = Array(UInt32,47)
icxx"
lldb_private::Error error;
$process->ReadMemory($tf,$(pointer(data)),$(sizeof(data)),error);
"
