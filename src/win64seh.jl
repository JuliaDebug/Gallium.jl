using StructIO
using COFF
@struct immutable RUNTIME_FUNCTION
    startoff::UInt32
    endoff::UInt32
    unwindoff::UInt32
end

immutable PData <: AbstractArray{RUNTIME_FUNCTION, 1}
    sec::SectionRef
end
import Base: getindex, length
PData(h::COFF.COFFHandle) = PData(
    collect(filter(x->sectionname(x)==ObjFileBase.mangle_sname(h,"pdata"),Sections(h)))[])
getindex(it::PData, n) = (1 <= n <= length(it) || throw(BoundsError());
    seek(it.sec, (n-1)*sizeof(RUNTIME_FUNCTION)); unpack(handle(it.sec), RUNTIME_FUNCTION))
length(it::PData) = Int(div(sectionsize(it.sec), sizeof(RUNTIME_FUNCTION)))

@struct immutable UNWIND_INFO
    # Low 3 bits are version
    # High 5 bits are flags
    VersionFlags::UInt8
    PrologueSize::UInt8
    NumUnwindCodes::UInt8
    FrameRegOff::UInt8
    # Opcodes
    # Exception Handler or chained unwind info
end

immutable UNWIND_CODE
    PrologueOffset::UInt8
    Operation::UInt8
end

@COFF.constants WIN64_UWOP "" begin
    const UWOP_PUSH_NONVOL      =  0
    const UWOP_ALLOC_LARGE      =  1
    const UWOP_ALLOC_SMALL      =  2
    const UWOP_SET_FPREG        =  3
    const UWOP_SAVE_NONVOL      =  4
    const UWOP_SAVE_NONVOL_FAR  =  5
    const UWOP_SAVE_XMM128      =  8
    const UWOP_SAVE_XMM128_FAR  =  9
    const UWOP_PUSH_MACHFRAME   =  0xa
end

_opinfo(Operation) = (Operation & 0xf, (Operation & 0xf0) >> 4)
opinfo(op) = _opinfo(op.Operation)
opinfo(op::UInt16) = _opinfo((op&0xff00)>>8)

function compute_alloc_op_size(ops, i)
    opcode, info = opinfo(ops[i])
    @assert opcode == UWOP_ALLOC_LARGE || opcode == UWOP_ALLOC_SMALL
    (opcode == UWOP_ALLOC_SMALL) && return (8 * (info + 1), 1)
    size = 0; nskip = 1
    if info == 0
        size = 8*ops[i+1]
        nskip = 2
    elseif info == 1
        size = UInt32(ops[i+1]) |
            (UInt32(ops[i+2]) << 8)
        nskip = 3
    else
        error("Invalid operation info")
    end
    (size, nskip)
end

function print_op(io, ops, i)
    opcode, info = opinfo(ops[i])
    print(io, WIN64_UWOP[opcode])
    if opcode == UWOP_PUSH_NONVOL
        println(io, ", register=", X86_64.seh_numbering[info])
        return 1
    elseif opcode == UWOP_ALLOC_LARGE || opcode == UWOP_ALLOC_SMALL
        size, nskip = compute_alloc_op_size(ops, i)
        println(io, ", size=", size)
        return nskip
    else
        println(io)
        return 1
    end
end

const UNW_FLAG_NHANDLER     =  0
const UNW_FLAG_EHANDLER     =  1
const UNW_FLAG_UHANDLER     =  2
const UNW_FLAG_CHAININFO    =  4


immutable UnwindEntry
    start::UInt64
    stop::UInt64
    info::UNWIND_INFO
    opcodes::Vector{UInt16}
end

immutable XPUnwindRef{SR<:ObjFileBase.SectionRef} <: Base.AbstractArray{UnwindEntry,1}
    xdata::SR
    pdata::SR
end
XPUnwindRef(xdata::SectionRef, pdata::SectionRef) = XPUnwindRef(xdata, pdata)
Base.length(xp::XPUnwindRef) = length(PData(xp.pdata))
Base.size(xp::XPUnwindRef) = (length(xp),)
function Base.getindex(xp::XPUnwindRef, idx)
    pentry = PData(xp.pdata)[idx]
    xdataoff = pentry.unwindoff - deref(xp.xdata).VirtualAddress
    seek(xp.xdata, xdataoff)
    info = unpack(handle(xp.xdata), UNWIND_INFO)
    UnwindEntry(pentry.startoff, pentry.endoff, info,
        read(handle(xp.xdata), UInt16, info.NumUnwindCodes))
end
