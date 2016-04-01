// clang -fPIC -c callback.c
// clang -shared -o hooking.so elfjump.o elfhook.o callback.o
void *hooking_jl_callback = 0;
void __attribute__ ((visibility ("default"))) hooking_jl_set_callback(void *fptr)
{
    hooking_jl_callback = fptr;
}
void test()
{
    ((void(*)())hooking_jl_callback)();
}
