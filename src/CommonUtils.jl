"""
    Module CommonUtils

General purpose utilities usable by all element types

"""

module CommonUtils
using LinearAlgebra # for I matrix in geometricFactors
using SparseArrays  # for spdiagm

# # convert array of tuples to tuples of arrays
# export unzip
# unzip(a) = map(x->getfield.(a, x), fieldnames(eltype(a)))

# convenience routines used for broadcasting over tuples of arrays
# used during time-stepping update of fields
export bcopy!, bmult
bcopy!(x,y) = x .= y
bmult(x,y) = x .* y

export rk45_coeffs, dopri45_coeffs

# 4th order 5-stage low storage Runge Kutta from Carpenter/Kennedy.
function rk45_coeffs()
    rk4a = [            0.0 ...
    -567301805773.0/1357537059087.0 ...
    -2404267990393.0/2016746695238.0 ...
    -3550918686646.0/2091501179385.0  ...
    -1275806237668.0/842570457699.0];

    rk4b = [ 1432997174477.0/9575080441755.0 ...
    5161836677717.0/13612068292357.0 ...
    1720146321549.0/2090206949498.0  ...
    3134564353537.0/4481467310338.0  ...
    2277821191437.0/14882151754819.0]

    rk4c = [ 0.0  ...
    1432997174477.0/9575080441755.0 ...
    2526269341429.0/6820363962896.0 ...
    2006345519317.0/3224310063776.0 ...
    2802321613138.0/2924317926251.0 ...
    1.0];
    return rk4a,rk4b,rk4c
end

function dopri45_coeffs()
    rk4a = [0.0             0.0             0.0             0.0             0.0             0.0         0.0
            0.2             0.0             0.0             0.0             0.0             0.0         0.0
            3.0/40.0        9.0/40.0        0.0             0.0             0.0             0.0         0.0
            44.0/45.0      -56.0/15.0       32.0/9.0        0.0             0.0             0.0         0.0
            19372.0/6561.0 -25360.0/2187.0  64448.0/6561.0  -212.0/729.0    0.0             0.0         0.0
            9017.0/3168.0  -355.0/33.0      46732.0/5247.0  49.0/176.0      -5103.0/18656.0 0.0         0.0
            35.0/384.0      0.0             500.0/1113.0    125.0/192.0     -2187.0/6784.0  11.0/84.0   0.0 ]

    rk4c = vec([0.0 0.2 0.3 0.8 8.0/9.0 1.0 1.0 ])

    # coefficients to evolve error estimator
    rk4E = vec([71.0/57600.0  0.0 -71.0/16695.0 71.0/1920.0 -17253.0/339200.0 22.0/525.0 -1.0/40.0 ])

    return rk4a,rk4E,rk4c
end


# export meshgrid from VectorizedRoutines
import VectorizedRoutines.Matlab.meshgrid
export meshgrid

# Convenience routines for identity matrices.
export eye #, speye
eye(n) = diagm(ones(n))
# eye(n) = spdiagm(0 => ones(n))

# spatial assembly routines
export connect_mesh, build_node_maps, geometric_factors
export build_periodic_boundary_maps, build_periodic_boundary_maps!

include("./geometric_mapping_functions.jl")
include("./mesh_functions.jl")
include("./node_map_functions.jl")

end
