parsevec(type, str) = str |>
  (x -> split(x, ", ")) |>
  (x -> map(y -> parse(type, y), x))
  
"Triangular SBP nodes with diagonal boundary matrices. Nodes from "
function diagE_sbp_nodes(elem::Tri, N; quadrature_strength=2*N-1)
    current_dir = @__DIR__
    if quadrature_strength==2*N-1
        # from Ethan Kubatko, private communication
        vars = matread(current_dir*"/data/sbp_nodes/KubatkoQuadratureRules.mat"); 
        rs = vars["Q_GaussLobatto"][N]["Points"]
        r,s = (rs[:,i] for i = 1:size(rs,2))
        w = vec(vars["Q_GaussLobatto"][N]["Weights"])
    elseif quadrature_strength==2*N
        # from Jason Hicken https://github.com/OptimalDesignLab/SummationByParts.jl/tree/work
        lines = readlines(current_dir*"/data/sbp_nodes/tri_diage_p$N.dat") 
        r = parsevec(Float64,lines[11])
        s = parsevec(Float64,lines[12])
        w = parsevec(Float64,lines[13])

        # convert Hicken format to biunit right triangle
        r = @. 2*r-1 
        s = @. 2*s-1
        w = 2.0 * w/sum(w)
    else
        error("No nodes found for N=$N with quadrature_strength = $quadrature_strength")
    end

    quad_rule_face = gauss_lobatto_quad(0,0,N+1) # hardcoded
    return (r,s,w),quad_rule_face 
end

function build_Ef_Fmask(rd_sbp::RefElemData)
    @unpack wq,wf,rq,sq,rf,sf,Nfaces = rd_sbp   
    rf,sf = (x->reshape(x,length(rf)÷Nfaces,Nfaces)).((rf,sf))
    Fmask = zeros(Int,length(rf)÷Nfaces,Nfaces) # 
    Ef = zeros(length(rf),length(rq)) # extraction matrix
    for i in eachindex(rq)
        for f = 1:rd_sbp.Nfaces
            tol = 1e-14
            id = findall(@. abs(rq[i]-rf[:,f]) + abs(sq[i]-sf[:,f]) .< tol)
            Fmask[id,f] .= i
            Ef[id .+ (f-1)*size(rf,1),i] .= 1
        end
    end
    return Ef,Fmask
end

struct DiagESummationByParts{T<:AbstractElemShape,DIM,Tv,Ti}
    elementType::T
    N::Int # poly degree
    points::NTuple{DIM,Vector{Tv}} # sbp nodes
    wq::Vector{Tv} # volume weights
    Qrst::NTuple{DIM,Matrix{Tv}} # differentiation matrices
    wf::Vector{Tv} # face weights
    nrstJ::NTuple{DIM,Vector{Tv}} # scaled outward normals on reference element
    Fmask::Vector{Ti} # face indices into volume nodes, e.g., vol_nodes[Fmask] = face_nodes
    Ef::Matrix{Tv} # face node extraction operator/"interpolation" to face nodes
end

"""
    function DiagESummationByParts(elementType::Tri, N; quadrature_strength = 2*N-1)
    function DiagESummationByParts(elementType::Quad, N)
    function DiagESummationByParts!(elementType, N, rd::RefElemData) 

Returns a DiagESummationByParts object. For `DiagESummationByParts!`, if `rd::RefElemData` is provided 
as an argument, it is modified to make sure that quadrature and face nodes match the SBP nodes.
"""
function DiagESummationByParts(elementType, N; kwargs...)
    # build polynomial reference element using quad rules
    rd_sbp = RefElemData(elementType, N) # just initialize to default, will get overwritten
    return DiagESummationByParts!(elementType, N, rd_sbp; kwargs...)
end

function DiagESummationByParts!(elementType::Quad, N, rd::RefElemData{2,Quad})

    # make 2D SBP nodes/weights
    r1D,w1D = gauss_lobatto_quad(0,0,N)
    sq,rq = vec.(NodesAndModes.meshgrid(r1D)) # this is to match ordering of nrstJ
    wr,ws = vec.(NodesAndModes.meshgrid(w1D)) 
    wq = wr.*ws
    quad_rule_vol = (rq,sq,wq)
    quad_rule_face = (r1D,w1D)

    rd_sbp = RefElemData(elementType, N, quad_rule_vol=quad_rule_vol, quad_rule_face=quad_rule_face)
    
    @unpack wf = rd_sbp
    Qr_sbp = rd_sbp.M*rd_sbp.Dr
    Qs_sbp = rd_sbp.M*rd_sbp.Ds
    
    Ef,Fmask = build_Ef_Fmask(rd_sbp)

    rd = rd_sbp # modify rd to match SBP nodes

    return DiagESummationByParts(elementType,N,(rq,sq),wq,(Qr_sbp,Qs_sbp),wf,rd_sbp.nrstJ,vec(Fmask),Ef)
end

function DiagESummationByParts!(elementType::Tri, N, rd::RefElemData{2,Tri}; quadrature_strength=2*N-1)
    
    quad_rule_vol, quad_rule_face = diagE_sbp_nodes(elementType, N; quadrature_strength=quadrature_strength)

    # build polynomial reference element using quad rules
    rd_sbp = RefElemData(elementType, N; quad_rule_vol=quad_rule_vol, quad_rule_face=quad_rule_face)

    # determine Fmask = indices of face nodes among volume nodes
    Ef,Fmask = build_Ef_Fmask(rd_sbp)

    # build traditional SBP operators from hybridized operators. 
    Qrh,Qsh,_ = hybridized_SBP_operators(rd_sbp)

    # See Section 3.2 of [High-order entropy stable dG methods for the SWE](https://arxiv.org/pdf/2005.02516.pdf) by Wu and Chan 2021.
    # [DOI](https://doi.org/10.1016/j.camwa.2020.11.006)
    Vh_sbp = [I(length(rd_sbp.rq)); Ef]
    Qr_sbp = Vh_sbp'*Qrh*Vh_sbp
    Qs_sbp = Vh_sbp'*Qsh*Vh_sbp

    rd = rd_sbp

    return DiagESummationByParts(elementType,N,rd_sbp.rstq,rd_sbp.wq,(Qr_sbp,Qs_sbp),
                                 rd_sbp.wf,rd_sbp.nrstJ,vec(Fmask),Ef)
end