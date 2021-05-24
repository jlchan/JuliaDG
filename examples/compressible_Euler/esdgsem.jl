using Plots
using OrdinaryDiffEq
using EntropyStableEuler
using StructArrays, LazyArrays, LinearAlgebra
using CheapThreads
using ESDG
using TimerOutputs # note: this is the NullOutput branch

N = 3
K1D = 32
CFL = .1
rd = RefElemData(Quad(), N)
sbp = DiagESummationByParts!(Quad(),N,rd) # modify rd 
VX,VY,EToV = uniform_mesh(Quad(),K1D)
md = MeshData(VX,VY,EToV,rd)
# md = make_periodic(md,rd)

# tags for boundary conditions
is_boundary_node = zeros(Int,size(md.xf))
is_boundary_node[md.mapB] .= 1 # change to boundary tag later

# get face centroids 
boundary_face_ids = findall(vec(md.FToF) .== 1:length(md.FToF))
function get_face_centroids(xf)
    Nfp = size(md.xf,1)÷rd.Nfaces
    xc = reshape(xf,Nfp,rd.Nfaces*md.K)
    return typeof(xf)(sum(xc,dims=1)/size(xc,1))
end
xc,yc = map(get_face_centroids,md.xyzf)
is_boundary_face = zeros(Int,rd.Nfaces*md.K)
is_boundary_face[boundary_face_ids] .= 1
bottom_boundary = findall(vec(@. abs(yc+1) < 50*eps()))
# is_boundary_face[bottom_boundary] .= 2
is_boundary_node = reshape(repeat(is_boundary_face',Nfp,1),Nfp*rd.Nfaces,md.K)
# scatter(xc[boundary_face_ids],yc[boundary_face_ids])


# is_boundary_node = Matrix{DataType}(undef,size(md.xf))
# fill!(is_boundary_node,Nothing)
# struct WallBC end
# is_boundary_node[md.mapB] .= WallBC
# function get_BC_state(bcType::WallBC,equation::EntropyStableEuler.Euler{2},normal,UM) 
#     return wall_boundary_state(equation,normal,UM)
# end


function Dirichlet_boundary_state(equation::EntropyStableEuler.Euler{d},xyzt...) where {d}
    return SVector{d+2}(U_function(xyzt...))
end

function pressure_outflow_state(equation::EntropyStableEuler.Euler{d},outflow_pressure,UM) where {d}
    ρ,ρu,ρv,_ = UM
    rho_unorm2 = (ρu^2 + ρv^2)/ρ
    E_out = outflow_pressure / (equation.γ-1) + .5*rho_unorm2
    return SVector{d+2}(ρ,ρu,ρv,E_out)
end

function wall_boundary_state(equation::EntropyStableEuler.Euler{2},normal,UM)
    ϱ, ϱu, ϱv, E = UM
    u, v = ϱu/ϱ, ϱv/ϱ
    nx, ny = normal
    u_n = u*nx + v*ny
    uP = u - 2*u_n*nx
    vP = v - 2*u_n*ny
    return SVector{4}(ϱ,ϱ*uP,ϱ*vP,E) 
end

function initial_condition(equation::EntropyStableEuler.Euler{2},x,y)
    a,b = .5,.5
    rho = 2.0 + .1*exp(-100*((x-a)^2+(y-b)^2))
    u,v = 0,0
    p = rho^equation.γ
    return prim_to_cons(equation,SVector{4}(rho,u,v,p))
end

function create_cache(equation,rd,md,sbp)

    Qr,Qs = sbp.Qrst
    QrskewTr = -.5*(Qr-Qr')
    QsskewTr = -.5*(Qs-Qs')
    invm = 1 ./ sbp.wq

    # tmp variables for entropy projection
    nvars, nvarslog = nvariables(equation), nvariables(equation) + 2
    Np = length(rd.r)
    Uf = StructArray{SVector{nvars,Float64}}(ntuple(_->similar(md.xf),nvars))
    Qlog = StructArray{SVector{nvarslog,Float64}}(undef,Np,md.K) # broadcast matches output type

    rhse = StructArray{SVector{nvars,Float64}}(undef,Np)
    rhse_threads = [similar(rhse) for _ in 1:Threads.nthreads()]

    cache = (;md,QrskewTr,QsskewTr,invm,Fmask=sbp.Fmask,wf=sbp.wf,
             Uf,Qlog,rhse_threads)

    return cache
end

# preallocate stuff
eqn = EntropyStableEuler.Euler{2}()
@inline two_pt_flux(UL,UR) = fS(EntropyStableEuler.Euler{2}(),UL,UR)
@inline two_pt_flux_logs(QL,QR) = fS_prim_log(EntropyStableEuler.Euler{2}(),QL,QR)
@inline cons_to_prim_logs(u) = cons_to_prim_beta_log(EntropyStableEuler.Euler{2}(),u)

timer = TimerOutput()
timer = NullTimer()

cache = (;create_cache(eqn,rd,md,sbp)..., equation=eqn, is_boundary_node, 
        fS_prim_log = two_pt_flux_logs, fS = two_pt_flux, dissipation=LxF_dissipation, 
        cons_to_prim_logs, solver = nothing, timer) 

function rhs!(dU,U,cache,t)    
    @unpack md = cache
    @unpack rxJ,sxJ,ryJ,syJ,J,nxJ,nyJ,sJ,mapP = md
    @unpack QrskewTr,QsskewTr,invm,Fmask,wf = cache
    @unpack equation, fS_prim_log, fS, dissipation = cache
    @unpack cons_to_prim_logs,Uf,Qlog = cache
    @unpack timer = cache
    
    @timeit timer "Primitive/log variable transforms" begin
        tmap!(cons_to_prim_logs,Qlog,U)
    end

    @timeit timer "Extract face vals" begin
        @batch for e = 1:size(U,2)
            for (i,vol_id) in enumerate(Fmask)        
                Uf[i,e] = U[vol_id,e]        
            end
        end
    end

    @batch for e = 1:md.K

        @timeit timer "Volume terms" begin        
            rhse = cache.rhse_threads[Threads.threadid()]
            fill!(rhse,zero(eltype(rhse)))

            QxTr = LazyArray(@~ @. 2 * (rxJ[1,e]*QrskewTr + sxJ[1,e]*QsskewTr))
            QyTr = LazyArray(@~ @. 2 * (ryJ[1,e]*QrskewTr + syJ[1,e]*QsskewTr))
            
            hadamard_sum_ATr!(rhse, (QxTr,QyTr), fS_prim_log, view(Qlog,:,e)) 
            # hadamard_sum_ATr!(rhse, (QxTr,QyTr), fS, view(U,:,e)) 
        end

        @timeit timer "Interface terms" begin
            for (i,vol_id) = enumerate(Fmask)
                UM = Uf[i,e]
                normal = SVector{2}(nxJ[i,e], nyJ[i,e]) / sJ[i,e]

                # if cache.is_boundary_node[i,e] == Nothing
                #     UP = Uf[mapP[i,e]]
                # else
                #     bcType = cache.is_boundary_node[i,e]
                #     UP = BCState(bcType,equations,getindex.(md.xyzf,i,e),t,normal,UM)
                # end

                if cache.is_boundary_node[i,e] == 1
                    UP = wall_boundary_state(equation,normal,UM)
                else
                    UP = Uf[mapP[i,e]]
                end            
                Fx,Fy = fS(UP,UM)
                diss = dissipation(equation,normal,UM,UP)
                val = (Fx * nxJ[i,e] + Fy * nyJ[i,e] + diss*sJ[i,e]) * wf[i]
                rhse[vol_id] += val
            end
        end

        @timeit timer "Store output" begin
            @. rhse = -rhse / J[1,e] # split up broadcasts to avoid allocations
            @. dU[:,e] = invm * rhse             
        end
    end

    return nothing
end



U = StructArray{SVector{nvariables(eqn),Float64}}(undef,size(md.x)...)
U .= ((x,y)->initial_condition(eqn,x,y)).(md.xyz...)
dU = similar(U)

@btime rhs!($dU,$U,$cache,$0.)

# rhs!(dU,U,cache,0.)
# reset_timer!(cache.timer)
# for i = 1:100
#     rhs!(dU,U,cache,0.)
# end

# h = 2/K1D
# CN = (N+1)*(N+2)/2 
# dt0 = CFL * h / CN
# tspan = (0.0,.5)
# ode = ODEProblem(rhs!,U,tspan,cache)
# sol = solve(ode, SSPRK43(), dt=dt0, save_everystep=false, callback=monitor_callback())

# show(cache.timer)

U = sol.u[end]
plot(DGTriPseudocolor(rd.Vp*StructArrays.component(U,1),rd,md),ratio=1,color=:blues)

