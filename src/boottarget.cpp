#define __STDC_LIMIT_MACROS
#define __STDC_CONSTANT_MACROS

#include <string>
#include "llvm/IR/Function.h"
#include "llvm/IR/Module.h"
#include "llvm/IR/LLVMContext.h"
#include "llvm/Support/raw_ostream.h"
#include "llvm/Bitcode/ReaderWriter.h"
#include "llvm/ExecutionEngine/ExecutionEngine.h"
extern llvm::Function* CloneFunctionToModule(llvm::Function *F, llvm::Module *destModule);
extern void jl_setup_module(llvm::Module *, bool);
extern llvm::ExecutionEngine *jl_ExecutionEngine;
extern llvm::TargetMachine *jl_TargetMachine;
static void setup_module(llvm::Module *m)
{
    m->addModuleFlag(llvm::Module::Warning, "Dwarf Version",2);
    m->addModuleFlag(llvm::Module::Error, "Debug Info Version",
        llvm::DEBUG_METADATA_VERSION);
    if (jl_ExecutionEngine) {
        m->setDataLayout(jl_ExecutionEngine->getDataLayout().getStringRepresentation());
        m->setTargetTriple(jl_TargetMachine->getTargetTriple().str());
    }
  }
jl_array_t *GetBitcodeForFunction(void *f) {
     llvm::LLVMContext &jl_LLVMContext = llvm::getGlobalContext();
     llvm::Function *llvmf = llvm::dyn_cast<llvm::Function>((llvm::Function*)f);
     if (!llvmf)
         jl_error("Expected Function*");

     // Make a copy of function
     llvm::Module *m = new llvm::Module(llvmf->getName(), jl_LLVMContext);
     setup_module(m);
     llvm::Function *f2 = CloneFunctionToModule(llvmf, m);
     m->dump();

     // Write it as bitcode to a memory buffer
     std::string Data;
     llvm::raw_string_ostream OS(Data);
     llvm::WriteBitcodeToFile(m, OS);

     return jl_pchar_to_array(Data.data(),Data.size());
 }
