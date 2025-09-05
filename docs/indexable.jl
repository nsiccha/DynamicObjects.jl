using DynamicObjects, Serialization

cheap_function(x) = x
expensive_function(x) = x^2
path = mktempdir()
@dynamicstruct struct Example
    cache_path = path
    p1[idx] = cheap_function(idx)
    @cached p2[idx] = expensive_function(idx)
    @cached p3[i,j,k] = i + 10*j + 100*k
end
e = Example()
e.p1[1]
e.p2[1]
e.p3[1,2,3]