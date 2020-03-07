using Revise # reduce need for recompile
using Plots
using LinearAlgebra

push!(LOAD_PATH, "./src") # user defined modules
using CommonUtils
using Basis1D
using Basis2DTri
using UniformTriMesh

"Define approximation parameters"
N   = 4 # The order of approximation
K1D = 16 # number of elements along each edge of a rectangle
CFL = .1 # relative size of a time-step
T   = .5 # final time

"Define mesh and compute connectivity
- (VX,VY) are and EToV is a connectivity matrix
- connect_mesh computes a vector FToF such that face i is connected to face j=FToF[i]"
VX,VY,EToV = uniform_tri_mesh(K1D,K1D)
FToF = connect_mesh(EToV,tri_face_vertices())
Nfaces,K = size(FToF)

# iids = @. (abs(abs(VX)-1)>1e-10) & (abs(abs(VY)-1)>1e-10)
# a = .2/K1D
# VX[iids] = @. VX[iids] + a*randn()
# VY[iids] = @. VY[iids] + a*randn()

"Construct matrices on reference elements
- r,s are vectors of interpolation nodes
- V is the matrix arising in polynomial interpolation, e.g. solving V*u = [f(x_1),...,f(x_Np)]
- inv(V) transforms from a nodal basis to an orthonormal basis.
- If Vr evaluates derivatives of the orthonormal basis at nodal points
- then, Vr*inv(V) = Vr/V transforms nodal values to orthonormal coefficients, then differentiates the orthonormal basis"
r, s = nodes_2D(N)
V = vandermonde_2D(N, r, s)
Vr, Vs = grad_vandermonde_2D(N, r, s)
invM = (V*V')
Dr = Vr/V
Ds = Vs/V

"Nodes on faces, and face node coordinate
- r1D,w1D are quadrature nodes and weights
- rf,sf = mapping 1D quad nodes to the faces of a triangle"
r1D, w1D = gauss_quad(0,0,N)
Nfp = length(r1D) # number of points per face
e = ones(Nfp,1) # vector of all ones
z = zeros(Nfp,1) # vector of all zeros
rf = [r1D; -r1D; -e];
sf = [-e; r1D; -r1D];
wf = vec(repeat(w1D,3,1));
Vf = vandermonde_2D(N,rf,sf)/V # interpolates from nodes to face nodes
LIFT = invM*(transpose(Vf)*diagm(wf)) # lift matrix used in rhs evaluation

"Construct global coordinates"
#- vx = VX[EToV'] = a 3xK matrix of vertex values for each element
#- V1*vx uses the linear polynomial defined by 3 vertex values to interpolate nodal points on the reference element to physical elements"
r1,s1 = nodes_2D(1)
V1 = vandermonde_2D(1,r,s)/vandermonde_2D(1,r1,s1)
x = V1*VX[transpose(EToV)]
y = V1*VY[transpose(EToV)]

"Compute connectivity maps: uP = exterior value used in DG numerical fluxes"
xf,yf = (x->Vf*x).((x,y))
mapM,mapP,mapB = build_node_maps((xf,yf),FToF)
mapM = reshape(mapM,Nfp*Nfaces,K)
mapP = reshape(mapP,Nfp*Nfaces,K)

"Make boundary maps periodic"
LX,LY = (x->maximum(x)-minimum(x)).((VX,VY)) # find lengths of domain
mapPB = build_periodic_boundary_maps(xf,yf,LX,LY,Nfaces*K,mapM,mapP,mapB)
mapP[mapB] = mapPB

"Compute geometric factors and surface normals"
rxJ, sxJ, ryJ, syJ, J = geometric_factors(x, y, Dr, Ds)

"nhat = (nrJ,nsJ) are reference normals scaled by edge length
- physical normals are computed via G*nhat, G = matrix of geometric terms
- sJ is the normalization factor for (nx,ny) to be unit vectors"
nrJ = [z; e; -e]
nsJ = [-e; e; z]
nxJ = (Vf*rxJ).*nrJ + (Vf*sxJ).*nsJ;
nyJ = (Vf*ryJ).*nrJ + (Vf*syJ).*nsJ;
sJ = @. sqrt(nxJ^2 + nyJ^2)

"=========== Done defining geometry and mesh ============="

"Define the initial conditions by interpolation"
p = @. exp(-700*(x^2+y^2))
pprev = copy(p) # 1st order accurate approximation to dp/dt = 0

"Time integration coefficients"
CN = (N+1)*(N+2)/2  # estimated trace constant
dt = CFL * 2 / (CN*K1D)
Nsteps = convert(Int,ceil(T/dt))
dt = T/Nsteps

"pack arguments into tuples"
ops = (Dr,Ds,LIFT,Vf)
vgeo = (rxJ,sxJ,ryJ,syJ,J)
fgeo = (nxJ,nyJ,sJ)
mapP = reshape(mapP,Nfp*Nfaces,K)
nodemaps = (mapP,mapB)

"Define function to evaluate the RHS"
function rhs_2ndorder(p,ops,vgeo,fgeo,nodemaps)
    # unpack arguments
    Dr,Ds,LIFT,Vf = ops
    rxJ,sxJ,ryJ,syJ,J = vgeo
    nxJ,nyJ,sJ = fgeo
    (mapP,mapB) = nodemaps

    # construct sigma
    pf = Vf*p # eval pressure at face points
    dp = pf[mapP]-pf # compute jumps of pressure
    pr = Dr*p
    ps = Ds*p
    dpdx = @. rxJ*pr + sxJ*ps
    dpdy = @. ryJ*pr + syJ*ps
    σxflux = @. dp*nxJ
    σyflux = @. dp*nyJ
    σx = (dpdx + .5*LIFT*σxflux)./J
    σy = (dpdy + .5*LIFT*σyflux)./J

    # compute div(σ)
    σxf,σyf = (x->Vf*x).((σx,σy))
    σxP,σyP = (x->x[mapP]).((σxf,σyf))
    pflux = @. .5*((σxP-σxf)*nxJ + (σyP-σyf)*nyJ)
    σxr,σyr = (x->Dr*x).((σx,σy))
    σxs,σys = (x->Ds*x).((σx,σy))
    dσxdx = @. rxJ*σxr + sxJ*σxs
    dσydy = @. ryJ*σyr + syJ*σys

    tau = 0
    rhsp = dσxdx + dσydy + LIFT*(pflux + tau*dp)

    return rhsp./J
end

#plotting nodes
rp, sp = equi_nodes_2D(15)
Vp = vandermonde_2D(N,rp,sp)/V
vv = Vp*p
gr(aspect_ratio=1, legend=false,
markerstrokewidth=0,markersize=2,
camera=(0,90),#zlims=(-1,1),clims=(-1,1),
axis=nothing,border=:none)

# Perform time-stepping
for i = 2:Nsteps

    rhsQ = rhs_2ndorder(p,ops,vgeo,fgeo,nodemaps)
    pnew = 2*p - pprev + dt^2 * rhsQ
    @. pprev = p
    @. p = pnew

    if i%10==0 || i==Nsteps
        println("Number of time steps $i out of $Nsteps")
        # vv = Vp*p
        # scatter(Vp*x,Vp*y,vv,zcolor=vv)
    end
end

vv = Vp*p
scatter(Vp*x,Vp*y,vv,zcolor=vv,camera=(45,45))