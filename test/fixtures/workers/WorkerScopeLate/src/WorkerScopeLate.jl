module WorkerScopeLate
using DynamicObjects
const VALUE = DynamicObjects.ScopedValues.ScopedValue(:unset)
__init__() = DynamicObjects.carry_to_worker!(@__MODULE__, :VALUE)
end
