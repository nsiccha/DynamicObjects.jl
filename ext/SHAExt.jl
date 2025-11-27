module SHAExt
using DynamicObjects, SHA, Serialization
DynamicObjects.persistent_hash(x) = begin
    b = IOBuffer()
    Serialization.serialize(b, x)
    bytes2hex(SHA.sha1(take!(b)))
end
end