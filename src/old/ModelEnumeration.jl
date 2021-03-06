
using Catlab.Programs.RelationalPrograms: parse_relation_context, parse_relation_call, parse_relation_diagram
using Catlab.WiringDiagrams
using DataStructures
using IterTools
using Combinatorics

include(joinpath(@__DIR__, "Sketch.jl"))
include(joinpath(@__DIR__, "DB.jl"))

const EqClass = Dict{Symbol, IntDisjointSets}
const ACDict = Dict{UInt64, Pair{StructACSet, ChaseStepData}}
const NewStuff = Vector{Pair{Symbol, Vector{Pair{Symbol, Int}}}}
const UpdateStuff = Vector{Tuple{Symbol, Int, Vector{Pair{Symbol, Int}}}}
const NewUpdate = Pair{NewStuff, UpdateStuff}
"""
Do a chase step: cone gen then TGDs, EGDs for each branch.
"""
function chasestep(F::Sketch, J::StructACSet)::Pair{ACDict, ACDict}
  verbose = true
  res, completed, srcs = ACDict(), ACDict(), F.schema[:vlabel][F.schema[:src]]
  #if verbose println("\tabout to add cones") end
  J_, csd_ = cone_gen(F, J) # modifies csd_ only - adds cones to copy
  ats = apply_tgds(F, J_, csd_) # make all possible choices for functions
  n = length(ats)
  for (i, (x, csd)) in enumerate(ats) # could be done in parallel
    e = apply_egds!(F, x, csd) # modifies csd
    merge!(F, x, e) # modifies x

    # Sanity checks
    is_iso = is_isomorphic(x, J)
    is_iso == isempty(csd) || error("iso csd $J \n$x \n$csd")
    if !is_iso
      if verbose println("\t$i/$n incomplete: hashing $(generate_json_acset(x))") end
      xhsh = canonical_hash(x; pres=F.crel_pres)
      if verbose println("\thashed!") end
      res[xhsh] = x => csd
    else
      !nontotal(F, x) || error("non total model")
      if verbose println("\t$i/$n complete! hashing $(generate_json_acset(x))") end
      completed[canonical_hash(x; pres=F.crel_pres)] = x => csd
    end
  end

  return res => completed
end

"""
Take a premodel from the DB and generate a set of models and premodels.
Insert these results into the DB. Return the IDs of the resulting premodels and
models.
"""
function chasestep_db(db::LibPQ.Connection, F::Sketch, i::Int
                     )::Pair{Vector{Int}, Vector{Int}}
  # check if we've already chased before
  if columntable(execute(db, "SELECT fired FROM Premodel WHERE Premodel_id=\$1",
                             [i]))[:fired][1]
    children = collect(columntable(execute(db,
      "SELECT child FROM Parent WHERE parent=\$1",[i]))[:child])
    if isempty(children)
      return Int[] => Int[]
    else
      modelchildren = columntable(execute(db,
        """SELECT Model_id, Premodel_id FROM Premodel JOIN Model
           USING (Premodel_id) WHERE Premodel_id IN ($(join(children, ",")))"""))
    end
    pmcs, mcs = [collect(modelchildren[x]) for x in [:premodel_id, :model_id]]
    # println("\tALREADY CHASED! model_ids: $mcs")
    return setdiff(children, pmcs) => mcs
  end
  m, I = get_premodel(db, i)
  msize = [k => nparts(I, k) for k in realobs(F)]
  println("NEW PREMODEL TO CHASE: #$i ($msize)")

  xs, ys = chasestep(m, I)
  pminds, minds = Int[], Int[]
  for (xhsh, (x, csd)) in xs
    # println("\tNew premodel $([k => nparts(x, k) for k in realobs(F)])")
    push!(pminds, add_premodel(db, F, x, i, csd, xhsh))
  end
  for (yhsh, (y, csd)) in ys
    println("\tNew model $([k => nparts(y, k) for k in realobs(F)])")
    push!(minds, add_model(db, F, y, i, csd, yhsh))
  end
  # println("MARKING AS FIRED")
  execute(db, "UPDATE Premodel SET fired = true WHERE Premodel_id = \$1", [i])
  return pminds => minds
end

"""
1. Enumerate elements of ?????? for an underlying graph with k nodes.
2. For each of these: (c???, ..., c???) create a term model with that many constants

Do the first enumeration by incrementing n_nonzero and finding partitions so
that ???(c???,...) = n_nonzero

In the future, this function will write results to a database
that hashes the Sketch as well as the set of constants that generated the model.

Also crucial is to decompose Sketch into subparts that can be efficiently solved
and have solutions stitched together.
"""
function combos_below(m::Int, n::Int)::Vector{Vector{Int}}
  res = Set{Vector{Int}}([zeros(Int,m)])
  n_const = 0 # total number of constants across all sets
  for n_const in 1:n
    for n_nonzero in 1:m
      # values we'll assign to nodes
      c_parts = partitions(n_const, n_nonzero)
      # Which nodes we'll assign them to
      indices = permutations(1:m,n_nonzero)
      for c_partition in c_parts
        for index_assignment in indices
          v = zeros(Int, m)
          v[index_assignment] = vcat(c_partition...)
          push!(res, v)
        end
      end
    end
  end
  return sort(collect(res))
end

function nontotal(F::Sketch, J::ACSet)::Bool
  for (src_i, e) in zip(F.schema[:src], F.schema[:elabel])
    srcobj, src = F.schema[:vlabel][src_i], add_srctgt(e)[1]
    missin = setdiff(parts(J, srcobj), J[src])
    if !isempty(missin)
      println("missing $srcobj <- $e: $missin")
      return true
    end
  end
  return false
end

"""
Find all models below a certain cardinality.

ignore_seen skips checking things in the database that were already chased.
If true, the final list of models may be incomplete, but it could be more
efficient if the goal of calling this function is merely to make sure all models
are in the database itself.
"""
function chase_below(db::LibPQ.Connection, F::Sketch, n::Int; ignore_seen=false
                    )::Vector{Int}
  unchased, res  = Set{Int}(), Set{Int}()
  m = length(realobs(F))
  for combo in combos_below(m, n)
    push!(unchased, init_premodel(db, F, combo))
  end
  seen = ignore_seen ? get_seen(db, F) : Set{Int}()
  while !isempty(unchased)
    mdl = pop!(unchased)
    m = get_premodel(db, mdl)[2]
    msize = [k => nparts(m, k) for k in realobs(F)]
    # println("chasing $mdl with size $msize")
    Ks, Ms = chasestep_db(db, F, mdl)
    # println("CHASESTEP RES: Ks=$Ks Ms=$Ms")
    function getidsize(x::Int)::Pair{UInt64, Int}
      z = columntable(execute(db,
        "SELECT hash,size FROM Premodel WHERE Premodel_id=\$1",[x]))
      return z[:hash][1] => z[:size][1]
    end
    filter!(k->let (i,s)=getidsize(k); i ??? seen && (s <= n) end, Ks)

    push!(seen, mdl)
    union!(unchased, setdiff(Ks, seen))
    union!(res, Ms)
  end
  return collect(res)
end

"""
Given a particular arrow and source for that arrow, find all targets (including
"free" = 0 for nonlimit targets) that do not immediately violate path eqs.
"""
function valid_poss(J::StructACSet, F::Sketch, e::Symbol, x::Int)::Vector{Int}
  res = tgt(F, e) ??? realobs(F) ? [0] : Int[]
  isempty(incident(J, x, add_srctgt(e)[1])) || error(
    "checking possiblities for something that's already determined")
  esrc, etgt = add_srctgt(e)
  temprel = add_part!(J, e; Dict([esrc=>x])...)
  # we could precompute this before everything to get Symbol -> [Eq] dict
  relevant_eqs = collect(filter(pq->e ??? vcat(pq[2],pq[3]), F.eqs))
  for tgt_val in parts(J,  tgt(F, e))
    #println("tgtval $tgt_val")
    set_subpart!(J, temprel, etgt, tgt_val)
    valid_tgt_val = true
    for (n,p,q) in relevant_eqs
      #println("\teq $n w/ p=$p ||| q=$q")
      if valid_tgt_val
        for strt in parts(J, src(F, p[1]))
          pres, qres = [
            let r=eval_path(x, J, Set([strt])); isempty(r) ? nothing : only(r)
            end for x in [p,q]]
          # length(pres) == 1 && length(qres) == 1 || error(
          #   "tgt val $tgt_val \np $p \nq $q\nstrt $strt pres $pres qres $qres")
          #pres, qres = collect(pres)[1], collect(qres)[1]
          if pres isa Int && qres isa Int
            if pres != qres
              #println("\t\tstart at $strt, p(x)=$pres q(x)=$qres")
            end
            valid_tgt_val &= pres == qres
          end
        end
      end
    end
    if valid_tgt_val
      push!(res, tgt_val)
    end
  end
  rem_part!(J, e, temprel)
  return res
end


"""
Add new elements when a function is dangling. Fire TGDs in all possible ways
(plus the 'free' way which uses fresh variables). This produces new premodels to
chase.
"""
function apply_tgds(F::Sketch, J::StructACSet, csd::ChaseStepData
                    )::Vector{Pair{StructACSet, ChaseStepData}}
  verbose = true
  if verbose
    println("Apply TGDs w/ J $J\ncsd $csd")
  end
  res = Pair{StructACSet, ChaseStepData}[]
  srcs, tgts = [F.schema[:vlabel][F.schema[x]] for x in [:src, :tgt]]
  # Calculate how many missing things we need of each type
  needs = [(d, nparts(J, dtgt),
            collect(setdiff(parts(J, ddom), J[add_srctgt(d)[1]])))
           for (d, ddom, dtgt) in zip(F.schema[:elabel], srcs, tgts)]
  lens = [length(x) for (_,_,x) in needs]
  csum = Dict(zip(F.schema[:elabel],zip(lens,vcat([0],cumsum(lens)[1:end-1]))))
  prod_args = vcat([[valid_poss(J, F, e, x) for x in xs] for (e, _, xs) in needs]...)
  println("needs $needs\nprod_args $prod_args\n")
  # branch on cartesian product of possibilities. 0 means fresh.
  if isempty(prod_args)
    return [J => csd]
  end
  for (_, choice) in enumerate(IterTools.product(prod_args...))
    Jc, Jcsd = deepcopy(J), deepcopy(csd)
    for (e, src, tgt, (_,_,eneed)) in zip(F.schema[:elabel], srcs, tgts, needs)
      esrc, etgt = add_srctgt(e)
      len, offset = csum[e]
      echoices = len == 0 ? [] : choice[1+offset:offset+len]
      for (x, echoice) in zip(eneed, echoices)
        if echoice == 0
          gx = add_part!(Jc, tgt) # add a fresh symbol
          push!(Jcsd.tgds[e], x => gx)
          add_part!(Jc, e; Dict([esrc=>x, etgt=>gx])...)
        else
          add_part!(Jc, e; Dict([esrc=>x, etgt=>echoice])...)
          push!(Jcsd.tgds[e], x => echoice)
        end
      end
    end
    # make sure no limit constraints violated
    conedata, coneviol = check_cones(F, Jc), false
    for d in values(conedata)
      for lvs in map(length,values(d))
        coneviol |= lvs > 1
      end
    end
    if !coneviol
      push!(res, Jc=>Jcsd)
    end
  end
  return res
end

"""
Identify cones already identified in an ACSet (i.e. this function doesn't
query). So we just look at the apex table for each cone. A cone with legs
l???...l??? will return a map from the targets for each leg to the apex index.
Because (for premodels) multiple elements in the apex object may have the same
leg values, this is in general a map [Int] -> [Int].
"""
function current_cones(F::Sketch, J::StructACSet,
                       eqclass::Union{Nothing, EqClass}=nothing
                       )::Dict{Symbol, Dict{Vector{Int}, Vector{Int}}}
  eqclasses = eqclass === nothing ? init_eq(F,J) : eqclass
  return Dict([c.apex=>current_cone(F, J, c, eqclasses) for c in F.cones])
end

"""Apply table-indexed equivalence relation to a vector of values (with an
equal-length vector of tables)"""
function eq_vec(eqclass::EqClass, tabs::Vector{Symbol}, inds::Vector{Int})
  length(tabs) == length(inds) || error("eq_vec needs equal length tabs/inds")
  [find_root!(eqclass[t], i) for (t, i) in zip(tabs, inds)]
end

"""
Compute `current_cones` for a single cone

Get the values for legs of each row of the apex (up to equivalence)
Return map from row values to apex index value.
"""
function current_cone(F::Sketch, J::StructACSet, cone::Cone, eqclass::EqClass
                     )::Dict{Vector{Int}, Vector{Int}}
  res  = DefaultDict{Vector{Int}, Vector{Int}}(Vector{Int})
  cols = [add_srctgt(e)[2] for e in last.(cone.legs)]
  tgts = [tgt(F,e) for e in last.(cone.legs)]
  coldata = [J[col] for col in cols]
  for (apex_ind, row) in enumerate(zip(coldata))
    if minimum(row) > 0
      res[eq_vec(eqclass, tgts, row)] = apex_ind
    end
  end
  return res
end


function add_new_stuff!(J::StructACSet, new_stuff::NewStuff)::Dict{Symbol, Vector{Int}}
  res = DefaultDict{Symbol, Vector{Int}}(Int[])
  for (apex, args) in new_stuff
    newapex = add_part!(J, apex)
    push!(res[apex], newapex)
    for (e, tgtval) in args
      s, t = add_srctgt(e)
      add_part!(J, e; Dict([s=>newapex, t=>tgtval])...)
    end
  end
  return res
end

"""Modifies newstuff"""
function cone_gen!(cone::Cone, J::StructACSet, newstuff::NewStuff)::Nothing
  verbose = true
  if verbose println("generating for cone $cone") end
  cones = conedata[cone.apex]
  if verbose && !isempty(cones) println("preexisting cones $(cones)") end
  # look for instances of the pattern (TODO cached version / only considered 'added' information)
  query_results = query(J, cone_query(cone))
  if verbose
    println("query_results $query_results")
  end
  for res in query_results # rely on order by same as order when precomputing
    resv = Vector{Int}(collect(res))
    if verbose println("res $res $resv") end
    if !haskey(cones, resv)
      if verbose println("$(cone.apex) is new w/ $(nparts(J, cone.apex))") end
      newargs = [e=>val for (val, (_, e)) in zip(resv,cone.legs)]
      push!(newstuff, cone.apex => newargs)
    end
  end
end

"""Add new elements required by cones. Modifies J."""
function cones_gen(F::Sketch, J_::StructACSet)::Pair{StructACSet, ChaseStepData}
  J = deepcopy(J_)
  csd = ChaseStepData()
  newstuff = Pair{Symbol, Vector{Pair{Symbol, Int}}}[]
  conedata = current_cones(F, J) # no queries made yet
  map(F.cones) do c cone_gen(c, J, newstuff) end
  # Add to J
  add_new_stuff!(J, newstuff)
  for (apex, args) in newstuff
    newapex = add_part!(J, apex)
    push!(csd.cones[apex], newapex)
  end

  return J => csd
end

"""
Compose relations starting with a subset of the composite domain to get a subset
of the (composite) codomain
"""
function eval_path(pth::Vector{Symbol}, J::StructACSet, xs::Set{Int})::Set{Int}
  # Iteratively update X to Y by searching through all (x,y) in R ??? X??Y
  for m in pth
    msrc, mtgt = add_srctgt(m)
    if isempty(xs)
      return xs
    else
      newxs = Set{Int}()
      for (jx, jy) in zip(J[msrc], J[mtgt])
        if jx ??? xs
          push!(newxs, jy)
        end
      end
      xs = newxs
    end
  end
  return xs
end

function cone_eqs!(F::Sketch, J::StructACSet,csd::ChaseStepData,eqclass::EqClass)::Nothing
  conedata = check_cones(F, J, eqclass)
  for cone in F.cones # could be done in parallel
    cones = conedata[cone.apex]
    # set equivalences
    for vs in filter(x->length(x) > 1, collect(values(cones)))
      push!(csd.cone_eqs[cone.apex], vs)
      for v in vs[2:end]
        union!(eqclass[cone.apex], vs[1], v)
      end
    end
  end
end

function check_path_eq!(F::Sketch, J::StructACSet,csd::ChaseStepData,eqclasses::EqClass, name::Symbol)::Nothing
  p, q = get_eq(F, name)
  eqc = eqclasses[tgt(F, p[end])]
  for x in parts(J, src(F, p[1]))
    for px in eval_path(p, J, Set([x]))
      for qx in (isempty(q) ? [x] : eval_path(q, J, Set([x])))
        if !in_same_set(eqc,px,qx)
          # println("name $name p $p q $q\n x $x px $px qx $qx \n $J")
          push!(csd.path_eqs[name], px => qx)
          union!(eqc, px, qx)
        end
      end
    end
  end
end

function path_eqs!(F::Sketch, J::StructACSet,csd::ChaseStepData,eqclasses::EqClass)::Nothing
  for (name, p, q) in F.eqs # could be done in parallel
    eqc = eqclasses[tgt(F, p[end])]
    for x in parts(J, src(F, p[1]))
      for px in eval_path(p, J, Set([x]))
        for qx in (isempty(q) ? [x] : eval_path(q, J, Set([x])))
          if !in_same_set(eqc,px,qx)
            # println("name $name p $p q $q\n x $x px $px qx $qx \n $J")
            push!(csd.path_eqs[name], px => qx)
            union!(eqc, px, qx)
          end
        end
      end
    end
  end
end

"""
Note which elements are equal due to relations actually representing functions
"""
function fun_eqs!(F::Sketch, J::StructACSet, csd::ChaseStepData, eqclass::EqClass
                 )::Nothing
  for d in F.schema[:elabel] # could be done in parallel
    dsrc, dtgt = add_srctgt(d)
    srcobj, tgtobj = src(F, d), tgt(F,d)
    eq_ys = DefaultDict{Int, Set{Int}}(Set{Int})
    for (src_i, tgt_i) in zip(J[dsrc], J[dtgt])
      push!(eq_ys[find_root!(eqclass[srcobj], src_i)], tgt_i)
    end
    for ys in filter(x->length(x)>1, collect(values(eq_ys)))
        push!(csd.fun_eqs[d], collect(ys))
        ymin = minimum(ys)
        for y in filter(!=(ymin), ys)
          union!(eqclass[tgtobj], y, ymin)
        end
    end
  end
end


function same_eq_classes(x::IntDisjointSets,y::IntDisjointSets)::Bool
  length(x)==length(y) || error("same_eq_class called on different lengths")
  for i in 1:length(x)
    for j in 1:length(x)
      if in_same_set(x, i, j) != in_same_set(y, i, j)
        return false
      end
    end
  end
  return true
end

"""Modifies eq"""
function apply_egds!(F::Sketch, J::StructACSet,csd::ChaseStepData)::EqClass
  # println("$i/$(length(ats)) applying egds to $(generate_json_acset(x))")
  eqclasses, changed = init_eq(F,J), true
  while changed
    start_eq = deepcopy(eqclasses)
    cone_eqs!(F,J,csd,eqclasses)
    path_eqs!(F,J,csd,eqclasses)
    fun_eqs!(F,J,csd,eqclasses)
    changed = !all([same_eq_classes(start_eq[o], eqclasses[o])
                    for o in F.schema[:vlabel]])
  end
  return eqclasses
end

