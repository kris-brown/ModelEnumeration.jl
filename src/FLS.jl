using Catlab.Present
using Catlab.Graphs
using JSON
using AutoHashEquals
using DataStructures: DefaultDict

using Catlab.Graphs.BasicGraphs: TheoryGraph
using Catlab.Theories
using Catlab.CategoricalAlgebra
using Catlab.CategoricalAlgebra.CSetDataStructures: struct_acset

import Base: isempty

include(joinpath(@__DIR__, "../../CSetAutomorphisms.jl/src/CSetAutomorphisms.jl"))

"""Edges and vertices labeled by symbols"""
@present TheoryLabeledGraph <: TheoryGraph begin
  Label::AttrType
  vlabel::Attr(V,Label)
  elabel::Attr(E,Label)
end;

@acset_type LabeledGraph_(TheoryLabeledGraph, index=[:src,:tgt])
const LabeledGraph = LabeledGraph_{Symbol}

"""Forget about the labels"""
function to_graph(lg::LabeledGraph_)::Graph
  G = Graph(nparts(lg, :V))
  add_edges!(G, lg[:src], lg[:tgt])
  return G
end

@auto_hash_equals struct Cone
  d::LabeledGraph
  apex::Symbol
  legs::Vector{Pair{Int, Symbol}}
  function Cone(d::LabeledGraph, apex::Symbol, legs::Vector{Pair{Int, Symbol}})
    l1, _ = zip(legs...) # l2 might have duplicates, e.g. monomorphism cone
    length(Set(l1)) == length(legs) || error("nonunique legs $legs")
    return new(d, apex, legs)
  end
end

@auto_hash_equals struct FLS
  name::Symbol
  schema::LabeledGraph
  cones::Vector{Cone}
  eqs::Vector{Tuple{Symbol, Vector{Symbol}, Vector{Symbol}}}
  cset::Type
  crel::Type
  function FLS(name::Symbol, schema::LabeledGraph, cones::Vector{Cone},
               eqs::Vector)
    # Check eqs are well-formed
    for (_, p, q) in eqs
      pe, qe = [[only(incident(schema, edge, :elabel)) for edge in x] for x in [p,q]]
      isempty(qe) || schema[:src][pe[1]] == schema[:src][qe[1]] || error("path eq don't share start point $p \n$q")
      isempty(qe) || schema[:src][pe[end]] == schema[:src][qe[end]] || error("path eq don't share end point $p \n$q")
      !isempty(qe) || schema[:src][pe[1]] == schema[:tgt][pe[end]] || error("path eq has self loop but p doesn't have same start/end $p \n$q")
      all([schema[:tgt][p1]==schema[:src][p2] for (p1, p2) in zip(pe, pe[2:end])]) || error("head/tail mismatch in p $p \n$q")
      all([schema[:tgt][q1]==schema[:src][q2] for (q1, q2) in zip(qe, qe[2:end])]) || error("head/tail mismatch in q $p \n$q")
    end
    # Check cones are well-formed
    for c in cones
      vert = only(incident(schema, c.apex, :vlabel))
      for (v, l) in c.legs
        edge = only(incident(schema, l, :elabel))
        schema[:src][edge] == vert || error("Leg does not come from apex $c")
        schema[:vlabel][schema[:tgt][edge]] == c.d[:vlabel][v] || error("Leg $l -> $v does not go to correct vertex $c")
        is_homomorphic(c.d, schema) || error("Cone diagram does not map into schema $c")
      end
    end
    return new(name, schema, cones, eqs, grph_to_cset(name, schema),
                grph_to_crel(name, schema))
  end
end

@auto_hash_equals struct ChaseStepData
  cones::DefaultDict{Symbol, Vector{Int}}
  tgds::DefaultDict{Symbol, Vector{Pair{Int, Int}}}
  path_eqs::DefaultDict{Symbol, Vector{Pair{Int, Int}}}
  fun_eqs::DefaultDict{Symbol, Vector{Vector{Int}}}
  cone_eqs::DefaultDict{Symbol, Vector{Vector{Int}}}
  function ChaseStepData()
    return new(DefaultDict{Symbol, Vector{Int}}(Vector{Int}),
               DefaultDict{Symbol, Vector{Pair{Int,Int}}}(Vector{Pair{Int,Int}}),
               DefaultDict{Symbol, Vector{Pair{Int,Int}}}(Vector{Pair{Int,Int}}),
               DefaultDict{Symbol, Vector{Vector{Int}}}(Vector{Vector{Int}}),
               DefaultDict{Symbol, Vector{Vector{Int}}}(Vector{Vector{Int}}))
  end
end

isempty(c::ChaseStepData) = all(map(isempty, [
  c.cones, c.tgds, c.path_eqs, c.fun_eqs, c.cone_eqs]))

csd_to_dict(csd::ChaseStepData) = Dict([
  "cones"=>Dict([string(k)=>v for (k,v) in collect(csd.cones)]),
  "tgds" =>Dict([string(k)=>v for (k,v) in csd.tgds]),
  "path_eqs"=>Dict([string(k)=>v for (k,v) in csd.path_eqs]),
  "fun_eqs"=>Dict([string(k)=>collect(v) for (k,v) in csd.fun_eqs]),
  "cone_eqs"=>Dict([string(k)=>collect(v) for (k,v) in csd.cone_eqs])])

src(F::FLS, e::Symbol) = F.schema[:vlabel][F.schema[:src][only(incident(F.schema, e, :elabel))]]
tgt(F::FLS, e::Symbol) = F.schema[:vlabel][F.schema[:tgt][only(incident(F.schema, e, :elabel))]]

cone_to_dict(c::Cone) = Dict([
  "d"=>generate_json_acset(c.d),
  "apex"=>string(c.apex),"legs"=>c.legs])
dict_to_cone(d::Dict)::Cone = Cone(
  parse_json_acset(LabeledGraph,d["d"]), Symbol(d["apex"]),
  [parse(Int, k)=>Symbol(v) for (k, v) in map(only, d["legs"])])
"""TO DO: add cone and eq info to the hash...prob requires CSet for FLS"""
Base.hash(F::FLS) = canonical_hash(to_graph(F.schema))
to_json(F::FLS) = JSON.json(Dict([
  :name=>F.name, :schema=>generate_json_acset(F.schema),
  :cones => [cone_to_dict(c) for c in F.cones],
  :eqs => [Dict([:name=>n,:p=>p,:q=>q]) for (n,p,q) in F.eqs]]))
function fls_from_json(s::String)::FLS
  p = JSON.parse(s)
  return FLS(Symbol(p["name"]), parse_json_acset(LabeledGraph, p["schema"]),
             [dict_to_cone(d) for d in p["cones"]],
             [(Symbol(pq["name"]), map(Symbol, pq["p"]),
               map(Symbol, pq["q"])) for pq in p["eqs"]])
end

add_srctgt(x::Symbol) = Symbol("src_$(x)") => Symbol("tgt_$(x)")


"""This should only be called inside constructing FLS ... move inside?"""
function grph_to_crel(name::Symbol,fls::LabeledGraph)::Type
  name_ = Symbol("rel_$name")
  pres = Presentation(FreeSchema)
  nv = length(fls[:vlabel])
  alledge = vcat([add_srctgt(e) for e in fls[:elabel]]...)
  xobs = [Ob(FreeSchema, s) for s in [fls[:vlabel]...,fls[:elabel]...]]
  for x in xobs
    add_generator!(pres, x)
  end
  for (i,(e, src, tgt)) in enumerate(zip(fls[:elabel],fls[:src], fls[:tgt]))
    s, t = add_srctgt(e)
    add_generator!(pres, Hom(s, xobs[nv+i], xobs[src]))
    add_generator!(pres, Hom(t, xobs[nv+i], xobs[tgt]))
  end
  expr = struct_acset(name_, StructACSet, pres, index=alledge)
  eval(expr)
  return eval(name_)
end

"""This should only be called inside constructing FLS ... move inside?"""
function grph_to_cset(name::Symbol, fls::LabeledGraph)::Type
  pres = Presentation(FreeSchema)
  xobs = [Ob(FreeSchema, s) for s in fls[:vlabel]]
  for x in xobs
    add_generator!(pres, x)
  end
  for (e, src, tgt) in zip(fls[:elabel], fls[:src], fls[:tgt])
    add_generator!(pres, Hom(e, xobs[src], xobs[tgt]))
  end
  expr = struct_acset(name, StructACSet, pres, index=fls[:elabel])
  eval(expr)
  return eval(name)
end


"""
Convert a functional C-Rel to a C-Set. Elements that are
not mapped by a relation are given a target value of 0. If this happens at all,
an output bool will be false
"""
function crel_to_cset(F::FLS, J::StructACSet)::Pair{StructACSet, Bool}
  res = F.cset() # grph_to_cset(F.name, F.schema)
  for o in F.schema[:vlabel]
    add_parts!(res, o, nparts(J, o))
  end
  partial = false
  for m in F.schema[:elabel]
    msrc, mtgt = add_srctgt(m)
    length(J[msrc]) == length(Set(J[msrc])) || error("nonfunctional $J")
    partial |= length(J[msrc]) != nparts(J, src(F, m))
    for (domval, codomval) in zip(J[msrc], J[mtgt])
      set_subpart!(res, domval, m, codomval)
    end
  end
  return res => partial
end

"""
Initialize a relation on a schema from either a model or a dict of cardinalities
for each object.
"""
function initrel(F::FLS,
                 I::Union{Nothing, Dict{Symbol, Int}, StructACSet}=nothing,
                 )::StructACSet
  if !(I isa StructACSet)
    dic = deepcopy(I)
    I = F.cset() # grph_to_cset(F.name, F.schema)
    for (k, v) in (dic === nothing ? [] : collect(dic))
      add_parts!(I, k, v)
    end
  end
  J = F.crel() # grph_to_crel(F.name, F.schema)
  # Initialize data in J from I
  for o in F.schema[:vlabel]
    add_parts!(J, o, nparts(I, o))
  end
  for d in F.schema[:elabel]
    hs, ht = add_srctgt(d)
    for (i, v) in filter(x->x[2]!=0, collect(enumerate(I[d])))
      n = add_part!(J, d)
    set_subpart!(J, n, hs, i)
    set_subpart!(J, n, ht, v)
    end
  end
  return J
end

function realobs(F::FLS)::Set{Symbol}
  return setdiff(Set(F.schema[:vlabel]), [c.apex for c in F.cones])
end
function relsize(F::FLS, I::StructACSet)::Int
  return sum([nparts(I, x) for x in realobs(F)])
end

function get_eq(F::FLS,name::Symbol)::Pair{Vector{Symbol}, Vector{Symbol}}
  return only([p=>q for (n,p,q) in F.eqs if n==name])
end

"""
Query that returns all instances of the base pattern. External variables
are labeled by the legs of the cone.
"""
function cone_query(c::Cone; verbose::Bool=false)::StructACSet
  vars = [Symbol("x$i") for i in nparts(c.d, :V)]
  typs = ["$x(_id=x$i)" for (i, x) in enumerate(c.d[:vlabel])]
  bodstr = vcat(["begin"], typs)
  for (e, s, t) in zip(c.d[:elabel], c.d[:src], c.d[:tgt])
    push!(bodstr, "$e(src_$e=x$s, tgt_$e=x$t)")
  end
  push!(bodstr, "end")
  exstr = "($(join(["$(v)_$i=x$k" for vs in values(vars) for (i, (k,v)) in enumerate(c.legs)],",") ))"
  ctxstr = "($(join(vcat(["x$i::$x" for (i, x) in enumerate(c.d[:vlabel])],),",")))"
  ex  = Meta.parse(exstr)
  ctx = Meta.parse(ctxstr)
  hed = Expr(:where, ex, ctx)
  bod = Meta.parse(join(bodstr, "\n"))
  if verbose
    println("ex $exstr\n ctx $ctxstr\n bod $(join(bodstr, "\n"))")
  end
  res = parse_relation_diagram(hed, bod)
  return res
end
