module SerializationExt
using DynamicObjects, Serialization
DynamicObjects.serialize(filename, value) = Serialization.serialize(filename, value)
DynamicObjects.deserialize(filename) = Serialization.deserialize(filename)
end