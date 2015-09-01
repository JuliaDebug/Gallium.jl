cxx"""
#include "lldb/Core/Stream.h"
#include "uv.h"

class JuliaStream : public lldb_private::Stream
{
public:
    JuliaStream (jl_value_t *io) :
        Stream (0, 4, lldb::eByteOrderLittle),
        m_io(io)
    {
    }

    virtual
    ~JuliaStream ()
    {
    }

    virtual void
    Flush ()
    {
        $:(flush(unsafe_pointer_to_objref(icxx"return m_io;")::IO); nothing);
    }

    virtual size_t
    Write (const void *s, size_t length)
    {
        $:(convert(Int,write(unsafe_pointer_to_objref(icxx"return m_io;")::IO,
          convert(Ptr{UInt8},icxx"return s;",icxx"return length;")))::Int; nothing);
        return length;
    }

private:
    jl_value_t *m_io;

};

class UvPipeStream : public lldb_private::Stream
{
public:
    UvPipeStream (uv_pipe_t *pipe) :
        Stream (0, 4, lldb::eByteOrderLittle),
        m_pipe(pipe)
    {
    }

    virtual
    ~UvPipeStream ()
    {
    }

    virtual void
    Flush ()
    {

    }

    virtual size_t
    Write (const void *s, size_t length)
    {
        uv_write_t req;
        uv_buf_t buf[] = {{.base = (char*)s, .len = length}};
        uv_write(&req,(uv_stream_t*)m_pipe,buf,1,NULL);
        return length;
    }

private:
    uv_pipe_t *m_pipe;

};

// A silly IO Handler to force LLDB to print state changes
class IOHandlerGallium :
    public lldb_private::IOHandler
{
public:

    IOHandlerGallium (lldb_private::Debugger &debugger) :
        IOHandler (debugger, IOHandler::Type::Other)
    {};

    ~IOHandlerGallium() override
    {

    }

    void
    Run () override
    {
        assert(false && "I'm sorry, Dave. I'm afraid I can't do that.");
    }

    void
    Cancel () override
    {

    }

    bool
    Interrupt () override
    {
        return false;
    }

    void
    GotEOF() override
    {
    }
};
"""
