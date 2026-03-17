module DynamicObjectsTests
using Test, Random, DynamicObjects, Serialization, TestModules
import DynamicObjects: @persist
include("DynamicObjectsTests.jl")
end

using TestModules
runtests!(DynamicObjectsTests)
