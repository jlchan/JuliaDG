"""
    meshgrid(x, y)

Matlab meshgrid function. Return 2D grid coordinates according to x and y.

# Examples
```jldoctest
julia> R = meshgrid(1:3, 1:3)
([1 2 3; 1 2 3; 1 2 3], [1 1 1; 2 2 2; 3 3 3])
```
"""
function meshgrid(x,y)
    X = repeat(transpose(x[:]), size(y[:], 1), 1)
    Y = repeat(y, 1, size(x, 1))
    return X, Y
end

"""
    meshgrid(x)

Matlab meshgrid function. Return 2D grid coordinates according to x and y=x.

# Examples
```jldoctest
```
"""
function meshgrid(x)
    return meshgrid(x,x)
end

"""
    meshgrid(x,y,z)

A hacky version of meshgrid which returns vectors, not tensors

# Examples
```jldoctest
```
"""
function meshgrid(x1D,y1D,z1D)
        Np = length(x1D)*length(y1D)*length(z1D)
        x = zeros(Np)
        y = zeros(Np)
        z = zeros(Np)
        sk = 1
        for k = 1:length(z1D)
                for j = 1:length(y1D)
                        for i = 1:length(x1D)
                                x[sk] = x1D[i]
                                y[sk] = y1D[j]
                                z[sk] = z1D[k]
                                sk += 1
                        end
                end
        end
        return x,y,z
end
