sess = Gallium.FakeMemorySession([(UInt64(0),reinterpret(UInt8,[UInt64(0)]))],
  Gallium.X86_64.X86_64Arch(), nothing)
@test Gallium.load(sess, RemotePtr{UInt64}(0)) == UInt64(0)
@test_throws ErrorException Gallium.load(sess, RemotePtr{UInt64}(8))
