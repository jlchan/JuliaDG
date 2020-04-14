using Revise # reduce need for recompile
using Plots
using LinearAlgebra
using SparseArrays

push!(LOAD_PATH, "./src") # user defined modules
using CommonUtils, Basis1D

"Approximation parameters"
N   = 5 # The order of approximation
K   = 32
CFL = .75
T   = .25

# viscosity, wave speed
ϵ   = .0
a   = 1

"Mesh related variables"
VX = LinRange(-1,1,K+1)
EToV = repeat([0 1],K,1) + repeat(1:K,1,2)

"Construct matrices on reference elements"
r,w = gauss_lobatto_quad(0,0,N)
V = vandermonde_1D(N, r)
Dr = grad_vandermonde_1D(N, r)/V
M = inv(V*V')

"Nodes on faces, and face node coordinate"
wf = [1;1]
Vf = vandermonde_1D(N,[-1;1])/V
LIFT = M\(transpose(Vf)*diagm(wf)) # lift matrix

"Construct global coordinates"
V1 = vandermonde_1D(1,r)/vandermonde_1D(1,[-1;1])
x = V1*VX[transpose(EToV)]

"Connectivity maps"
xf = Vf*x
mapM = reshape(1:2*K,2,K)
mapP = copy(mapM)
mapP[1,2:end] .= mapM[2,1:end-1]
mapP[2,1:end-1] .= mapM[1,2:end]

"Make maps periodic"
mapP[1] = mapM[end]
mapP[end] = mapM[1]

"Geometric factors and surface normals"
J = repeat(transpose(diff(VX)/2),N+1,1)
nxJ = repeat([-1;1],1,K)
rxJ = 1

"Quadrature operators"
rq,wq = gauss_quad(0,0,2*N)
rq,wq = gauss_lobatto_quad(0,0,N)
Vq = vandermonde_1D(N,rq)/V # vandermonde_1D(N,rq) * inv(V)
M = Vq'*diagm(wq)*Vq
LIFT = M\transpose(Vf)
Pq = (Vq'*diagm(wq)*Vq)\(Vq'*diagm(wq))

"=========== done with mesh setup here ============ "

"pack arguments into tuples"
ops = (Dr,LIFT,Vf,Vq,Pq)
vgeo = (rxJ,J)
fgeo = (nxJ,)

function burgers_exact_sol(u0,x,T,dt)
    Nsteps = ceil(Int,T/dt)
    dt = T/Nsteps
    u = u0(x)
    for i = 1:Nsteps
        t = i*dt
        u = @. u0(x-u*t)
    end
    return u
end

function rhs(u,ops,vgeo,fgeo,mapP,params...)
    # unpack arguments
    Dr,LIFT,Vf,Vq,Pq = ops
    rxJ,J = vgeo
    nxJ, = fgeo

    # construct sigma
    uf = Vf*u
    du = uf[mapP]-uf
    σxflux = @. .5*du*nxJ
    dudx = rxJ.*(Dr*u)
    σx = (dudx + LIFT*σxflux)./J

    # define viscosity, wavespeed parameters
    ϵ = params[1]
    a = params[2]
    tau = 1

    # compute dσ/dx
    σxf = Vf*σx
    σxP = σxf[mapP]
    σflux = @. .5*((σxP-σxf)*nxJ + tau*du)
    dσxdx = rxJ.*(Dr*σx)
    rhsσ = dσxdx + LIFT*(σflux)

    # compute df(u)/dx (or u*(du/dx))

    # # nodal collocation
    # flux = @. u^2/2
    # dfdx = rxJ.*(Dr*flux)
    # flux_f = Vf*flux
    # df = flux_f[mapP] - flux_f
    # uflux = @. .5*(df*nxJ - tau*du*abs(.5*(uf[mapP]+uf))*abs(nxJ))
    # rhsu = dfdx + LIFT*uflux

    # # over-integration - version 1
    # f_u = .5*(Vq*u).^2
    # vol_rhs = rxJ.*(M\(-Dr'*Vq'*diagm(wq)*f_u))
    # uf   = Vf*u
    # uP   = uf[mapP]
    # f_uf = @. (uf).^2/2
    # flux = @. .5*(f_uf[mapP]+f_uf)*nxJ - tau*abs(.5*(uP+uf))*du # an educated guess for the flux
    # rhsu = vol_rhs + LIFT*flux
    #
    # # over-integration - version 2
    # flux = .5*Pq*((Vq*u).^2)
    # dfdx = rxJ.*(Dr*flux)
    # uf   = Vf*u
    # f_uf = @. (uf).^2/2
    # df = .5*(f_uf[mapP]+f_uf) - (Vf*flux)
    # uflux = @. df*nxJ - tau*abs(.5*(uP+uf))*du
    # rhsu = dfdx + LIFT*uflux

    # split form
    f_u = (Vq*u).^2
    dfdx = rxJ.*(M\(-Dr'*Vq'*diagm(wq)*f_u)) # conservative part
    ududx = Pq*((Vq*u).*(Vq*Dr*u))           # non-conservative part
    uf = Vf*u
    uP = uf[mapP]
    df = @. .5*(uP^2 + uP*uf)
    uflux = @. (df*nxJ - .5*tau*du*max(abs(uf[mapP]),abs(uf))*abs(nxJ))
    rhsu = (1/3)*(dfdx + ududx + LIFT*uflux)

    # DG-SEM split form: Vq = I, Pq = I
    f_u   = u.^2
    dfdx  = rxJ.*(Dr*f_u)        # conservative part
    ududx = u.*(Dr*u)           # non-conservative part
    uf = Vf*u
    uP = uf[mapP]
    df = @. .5*(uP^2 + uP*uf) - uf.^2
    uflux = @. (df*nxJ - .5*tau*du*max(abs(uf[mapP]),abs(uf))*abs(nxJ))
    rhsu = (1/3)*(dfdx + ududx + LIFT*uflux)

    # combine advection and viscous terms
    rhsu = rhsu - ϵ*rhsσ
    return -rhsu./J
end


"Low storage Runge-Kutta time integration"
rk4a,rk4b,rk4c = rk45_coeffs()
CN = (N+1)*(N+2)/2  # estimated trace constant
dt = CFL * 2 / (CN*K)
Nsteps = convert(Int,ceil(T/dt))
dt = T/Nsteps

"Perform time-stepping"
# u0(x) = @. exp(-100*(x+.5)^2)
u0(x) = @. -sin(pi*x)
u = u0(x)

ulims = (minimum(u)-.5,maximum(u)+.5)

# filter_weights = ones(N+1)
# filter_weights[end-2] = .5
# filter_weights[end-1] = .1
# filter_weights[end] = .0
# Filter = V*(diagm(filter_weights)/V)

"plotting nodes"
Vp = vandermonde_1D(N,LinRange(-1,1,100))/V
gr(aspect_ratio=1,legend=false,markerstrokewidth=1,markersize=2)
# plot()

wJq = diagm(wq)*(Vq*J)

resu = zeros(size(x)) # Storage for the Runge kutta residual storage
energy = zeros(Nsteps)
interval = 25
for i = 1:Nsteps
    for INTRK = 1:5
        rhsu = rhs(u,ops,vgeo,fgeo,mapP,ϵ,a)
        # rhsu .= (Filter*rhsu)
        @. resu = rk4a[INTRK]*resu + dt*rhsu
        @. u   += rk4b[INTRK]*resu

        # u .= (Filter*u)
    end
    energy[i] = sum(sum(wJq.*(Vq*u).^2))

    if i%interval==0 || i==Nsteps
        println("Number of time steps $i out of $Nsteps")
        # plot(Vp*x,Vp*u,ylims=ulims,title="Timestep $i out of $Nsteps",lw=2)
        # scatter!(x,u,xlims=(-1,1),ylims=ulims)
    end
end

scatter(x,u,markersize=4) # plot nodal values
display(plot!(Vp*x,Vp*u)) # plot interpolated solution at fine points

# compute using method of characteristics with small time-steps
rq2,wq2 = gauss_quad(0,0,3*N)
Vq2 = vandermonde_1D(N,rq2)/V
xq2 = Vq2*x
wJq2 = diagm(wq2)*(Vq2*J)
L2err = sqrt(sum(wJq2.*(Vq2*u - burgers_exact_sol(u0,xq2,T,dt/100)).^2))
@show L2err
