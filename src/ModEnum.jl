module ModEnum
export chase_step, chase_step_db, chase_set, sat_eqs, path_eqs!, prop_path_eq_info!

using ..Sketches
using ..DB
using ..Models
using ..Limits

using Catlab.WiringDiagrams, Catlab.CategoricalAlgebra
using Catlab.Programs.RelationalPrograms: parse_relation_diagram
using Combinatorics, DataStructures, Distributed
using LibPQ, Tables

"""
parallelize by adding Threads.@threads before a for loop. Hard to do w/o
creating bugs.
"""

# Type synonyms
###############
const Poss = Tuple{Symbol, Int, Modify}
struct Branch
  branch::Symbol     # either a morphism or a cocone apex
  val::Int           # index of the src element index or the cocone
  poss::Vector{Poss} # Modifications: possible ways of branching
end
const b_success = Branch(Symbol(),0,[])

# Toplevel functions
####################
"""
Take a sketch and a premodel and perform one chase step.

1. Build up equivalence classes using path equalities
2. Compute cones and cocones
3. Consider all TGDs (foreign keys that point to nowhere).
  - Pick one and return the possible decisions for branching on it
"""
function chase_step(S::Sketch, J::StructACSet, d::Defined
                    )::Union{Nothing,Tuple{StructACSet, Defined, Branch}}
  # Initialize variables
  verbose = false
  fail, J = handle_zero_one(S, J, d) # doesn't modify J
  if fail return nothing end

  ns, lc = NewStuff(), LoneCones()

  # this loop might not be necessary. If one pass is basically all that's
  # needed, then this loop forces us to run 2x loops
  for cnt in Iterators.countfrom()
    if verbose && cnt > 1 println("\tchase step iter #$cnt") end
    if cnt > 10 error("TOO MANY ITERATIONS") end
    changed, failed, J, lc, d = propagate_info(S, J, d)
    if failed return nothing end
    if !changed break end
  end

  # add new things that make J bigger
  # update_crel!(J, ns)

  # Flag (co)cones as defined, now that we've added the newstuff
  for c in filter(c->c.apex ∉ d[1], vcat(S.cones,S.cocones))
    if (c.d[:vlabel] ⊆ d[1]) && (c.d[:elabel] ⊆ d[2])
      if verbose
        println("flagging $(c.apex) as defined: $(sizes(S, J)) \n\td $d")
      end
      push!(d[1], c.apex)
      union!(d[2], Set(last.(c.legs)))
    end
  end
  # crel_to_cset(S, J)
  # println("J Res "); show(stdout, "text/plain", crel_to_cset(S, J)[1])
  fail, J = handle_zero_one(S, J, d) # doesn't modify J
  update_defined!(S, J, d)
  if fail return nothing end
  pri = priority(S, d, [k for (k,v) in lc if !isempty(v)])
  if isnothing(pri) return (J, d, b_success) end
  i::Union{Int,Nothing} = haskey(lc, pri) ? first(collect(lc[pri])) : nothing
  return (J, d, get_possibilities(S, J, d, pri, i))
end

"""Set cardinalities of 0 and 1 objects correctly + maps into 1"""
function handle_zero_one(S::Sketch, J::StructACSet, d::Defined)::Pair{Bool,StructACSet}
  J = deepcopy(J)
  eq = init_eq(S, J)

  for t1 in one_ob(S)
    push!(d[1], t1)
    unions!(eq[t1], collect(parts(J, t1)))
    if nparts(J, t1) == 0
      add_part!(J, t1)
    end
    for e in filter(e->tgt(S,e)==t1, S.schema[:elabel])
      [add_rel!(S, J, d, e, i, 1) for i in parts(J, src(S, e))]
    end
  end
  merge!(S, J, eq)
  for t0 in zero_ob(S)
    push!(d[1], t0)
    if nparts(J, t0) > 0
      return true => J
    end
  end
  return false => J
end

"""
Use path equalities, functionality of FK relations, cone/cocone constraints to
generate new data and to quotient existing data. Separate information that can
be safely applied within a while loop (i.e. everything except for things
related to newly added elements).
"""
function propagate_info(S::Sketch, J::StructACSet, d::Defined
          )::Tuple{Bool, Bool, StructACSet, LoneCones, Defined}
  verbose, changed = false, false
  eq = init_eq(S, J) # trivial equivalence classes
  # Path Eqs
  pchanged, pfail = path_eqs!(S,J,eq,d)
  changed |= pchanged
  if pfail return (changed, true, J, LoneCones(), d) end
  if verbose println("\tpchanged $pchanged: $(sizes(S, J)) ") end
  if pchanged update_defined!(S,J,d) end
  # Cones
  cchanged, cfail = compute_cones!(S, J, eq, d)
  changed |= cchanged
  if cfail return (changed, true, J, LoneCones(), d) end
  if verbose println("\tcchanged $cchanged $(sizes(S, J)) ") end
  if cchanged update_defined!(S,J,d) end

  # Cocones
  cochanged, cfail, lone_cones = compute_cocones!(S, J, eq, d)
  if verbose println("\tcochanged $cochanged: $(sizes(S, J)) ") end
  changed |= cochanged
  if cfail return (changed, true, J, LoneCones(), d) end
  if cochanged update_defined!(S,J,d) end

  # because this is at the end, chased premodels should be functional
  fchanged, ffail = fun_eqs!(S, J, eq, d)
  if verbose println("\tfchanged $fchanged: $(sizes(S, J))") end
  changed |= fchanged
  if ffail return (changed, true, J, LoneCones(), d) end
  if fchanged update_defined!(S,J,d) end
  cs = crel_to_cset(S, J) # will trigger a fail if it's nonfunctional
  #if verbose show(stdout, "text/plain", cs[1]) end

  return (changed, false, J, lone_cones, d)
end

"""
For each unspecified FK, determine its possible outputs that don't IMMEDIATELY
violate a cone/cocone constraint. Additionally consider an option that the FK
points to a fresh element in the codomain table.

It may seem like, if many sets of possibilities has only one option, that we
could safely apply all of them at once. However, this is not true. If a₁ and a₂
map to B (which is empty), then branching on either of these has one
possibility; but the pair of them has two possibilities (both map to fresh b₁,
or map to fresh b₁ and b₂).
"""
function get_possibilities(S::Sketch, J::StructACSet,  d::Defined, sym::Symbol,
                           i::Union{Nothing, Int}=nothing)::Branch
  if isnothing(i) # branching on a foreign key
    src_tab, tgt_tab = src(S,sym), tgt(S,sym)
    esrc, _ = add_srctgt(sym)
    # sym ∉ d[2] || error("$d but branching $sym: $src_tab -> $tgt_tab")
    u = first(setdiff(parts(J,src_tab), J[esrc]))
    # possibilities of setting `u`'s value of FK `e`
    subres = Poss[]
    # First possibility: a `e` sends `u` to a fresh ID
    if tgt_tab ∉ d[1]
      mu = Modify()
      mu.newstuff.ns[tgt_tab][(sym, u)] = NewElem()
      push!(mu.newstuff.ns[tgt_tab][(sym, u)].map_in[sym], u)
      push!(subres, (sym, 0, mu))
    end
    # Remaining possibilities (check satisfiability w/r/t cocones/cones)
    for p in 1:nparts(J,tgt_tab)
      m = Modify()
      push!(m.update, (sym, u, p))
      push!(subres, (sym, p, m))
    end
    return Branch(sym, u, subres)
  else # Orphan cocone apex element.
    cocone = only([c for c in S.cocones if c.apex == sym])
    val = first(vs) # They're all symmetric, so we just need one.
    subres = Poss[] # all possible ways to map to an element of this cocone
    for leg in last.(cocone.legs)
      srctab = src(S, leg)
      src_fk = add_srctgt(leg)[1]
      # Consider a new element being added and mapping along this leg
      if srctab ∉ z1 && srctab ∉ d[1]
        fresh = Modify()
        fresh.newstuff.ns[srctab][(k, leg)] = NewElem()
        fresh.newstuff.ns[srctab][(k, leg)].map_out[leg] = val
        push!(subres, (leg, nparts(J, srctab) + 1, fresh))
      end
      # Consider existing elements for which this leg has not yet been set
      for u in setdiff(parts(J, srctab), J[src_fk])
        m = Modify()
        push!(m.update, (leg, u, val))
        push!(subres, (leg, u, m))
      end
    end
    return Branch(cocone.apex, val, subres)
  end
end

# DB
####

"""Explore a premodel and add its results to the DB."""
function chase_step_db(db::T, S::Sketch, premodel_id::Int,
                       redo::Bool=false)::Pair{Bool, Vector{Int}} where {T<:DBLike}
  verbose = 1
  # Check if already done
  if !redo
    redo_res = handle_redo(db, premodel_id)
    if !isnothing(redo_res) return redo_res end
  end

  J_, d_ = get_premodel(db, S, premodel_id)
  if verbose > 0 println("CHASING PREMODEL #$premodel_id: $(sizes(S, J_))") end
  # show(stdout, "text/plain", crel_to_cset(S, J_)[1])
  cs_res = chase_step(S, create_premodel(S, J_), d_)

  # Failure
  if isnothing(cs_res)
    if verbose > 0 println("\t#$premodel_id: Fail") end
    set_fired(db, premodel_id)
    set_failed(db, premodel_id, true)
    return false => Int[]
  end

  # Success
  set_failed(db, premodel_id, false)

  J, d, branch = cs_res
  # println("\tChased premodel: $(sizes(S, J))")
  # show(stdout, "text/plain", crel_to_cset(S, J)[1])
  chased_id = add_premodel(db, S, J, d; parent=premodel_id)
  println("new chased id = $chased_id")

  # Check we have a real model
  if branch == b_success
    if verbose > 0 println("\t\tFOUND MODEL") end
    return true => [add_model(db, S, J, d, chased_id)]
  else
    if verbose > 0 println("\tBranching #$premodel_id on $(branch.branch)") end
    res = Int[]
    for (e,i,mod) in branch.poss
      (J__, d__) = deepcopy((J,d))
      update_crel!(S, J__, d__, mod)
      bstr = string((branch.branch, branch.val, e, i))
      push!(res, add_branch(db, S, bstr, chased_id, J__, d__))
    end
    return false => res
  end
end

"""
If there's nothing to redo, return nothing. Otherwise return whether or not
the premodel is a model + its value
"""
function handle_redo(db::Db, premodel_id::Int
                      )::Union{Nothing,Pair{Bool,Vector{Int}}}
  z = columntable(execute(db.conn, """SELECT 1 FROM Premodel WHERE
  Premodel_id=\$1 AND failed IS NULL""", [premodel_id]))
  if isempty(z)
    z = columntable(execute(db.conn, """SELECT Model_id FROM Model
                                  WHERE Premodel_id=\$1""", [premodel_id]))
    if !isempty(z)
      return true => [only(z[:premodel_id])]
    else
      z = columntable(execute(db.conn, """SELECT Choice.child FROM Fired JOIN
      Choice ON Fired.child=Choice.parent WHERE Fired.parent=\$1""", [premodel_id]))
      return false => collect(z[:child])
    end
  end
end

"""
"""
function handle_redo(es::EnumState, premodel_id::Int
                      )::Union{Nothing,Pair{Bool,Vector{Int}}}
  if premodel_id <= length(es.pk) return nothing end
  hsh = es.pk[premodel_id]
  return (hsh ∈ es.models) => [premodel_id]
end
"""
Find all models below a certain cardinality. Sometimes this exploration process
generates models *larger* than what we start off with, yet these are eventually
condensed to a small size.
`extra` controls how much bigger than the initial cardinality we are willing to
explore intermediate models.
`ignore_seen` skips checking things in the database that were already chased.
If true, the final list of models may be incomplete, but it could be more
efficient if the goal of calling this function is merely to make sure all models
are in the database itself.
"""
function chase_below(db::DBLike, S::Sketch, n::Int; extra::Int=3,
                     filt::Function=(x->true))::Nothing
  ms = []
  for combo in combos_below(length(free_obs(S)), n)
    ps = mk_pairs(collect(zip(free_obs(S), combo)))
    if filt(Dict(ps))
      premod = create_premodel(S, ps)
      push!(ms,premod=>init_defined(S, premod))
    end
  end
  chase_set(db, S, ms, n+extra)
end

"""
Keep processing until none remain
v is Vector{Pair{StructACSet,Defined}}
"""
function chase_set(db::DBLike,S::Sketch,
                   v::Vector, n::Int)::Nothing
  for (m,d) in v
    add_premodel(db, S, m, d)
  end
  while true
    todo = get_premodel_ids(db; sketch=S, maxsize=n)
    if isempty(todo)
      break
    else
      #pmap(mdl -> chase_step_db(db, S, mdl), todo)

      for mdl in todo # Threads.@threads?
        chase_step_db(db, S, mdl)
      end
    end
  end
end

# Equalities
############

"""
Note which elements are equal due to relations actually representing functions

a₁  -> b₁
a₂  -> b₂
a₁  -> b₃
a₃  -> b₄

Because a₁ is mapped to b₁ and b₃, we deduce b₁=b₃. If the equivalence relation
has it such that a₂=a₃, then we'd likewise conclude b₂=b₄

Quotients by the equivalence class at the end
"""
function fun_eqs!(S::Sketch, J::StructACSet, eqclass::EqClass, def::Defined
                 )::Pair{Bool,Bool}
  # println([k=>(nparts(J,k),length(v)) for (k,v) in pairs(eqclass)])
  cols = [:elabel, [:src, :vlabel], [:tgt, :vlabel]]
  changed = false
  for (d, srcobj, tgtobj) in collect(zip([S.schema[x] for x in cols]...))
    dsrc, dtgt = add_srctgt(d)
    srcobj, tgtobj = src(S, d), tgt(S,d)
    for src_eqset in collect.(eq_sets(eqclass[srcobj]; remove_singles=false))
      tgtvals = Set(J[vcat(incident(J, src_eqset, dsrc)...), dtgt])
      if length(tgtvals) > 1
        if tgtobj ∈ def[1]
          #println("Fun Eq of $d (src: $src_eqset) merges $tgtobj: $tgtvals")
          #show(stdout, "text/plain", J)
          return changed => true
        else
          for (i,j) in Iterators.product(tgtvals, tgtvals)
            if !in_same_set(eqclass[tgtobj], i, j)
              changed = true
              union!(eqclass[tgtobj], i, j)
            end
          end
        end
      end
    end
  end
  merge!(S, J, eqclass)
  return changed => false
end

# Path equality
###############
"""
Use set of path equalities starting from the same vertex to possibly resolve
some foreign key values.

Each set of equalities induces a rooted diagram
         ↗B↘
        X -> A
        ↘ C ↗

- We can imagine associated with each vertex there is a set of possible values.
- We initialize the diagram with a singleton value at the root (and do this for
each object in the root's table).
- For each arrow out of a singleton object where we know the value of that FK,
  we can set the value of the target to that value.
- For each arrow INTO a table with some information, we can restrict the poss
  values of the source by looking at the preimage (this only works if this arrow
  is TOTALLY defined).
- Iterate until no information is left to be gained
"""
function path_eqs!(S::Sketch, J::StructACSet, eqclasses::EqClass,
                    d::Defined)::Pair{Bool, Bool}
  changed = false
  for (s, eqd) in zip(S.schema[:vlabel], S.eqs)
    poss_ = [eq_reps(eqclasses[v]) for v in eqd[:vlabel]]
    for v in eq_reps(eqclasses[s])
      poss = deepcopy(poss_)
      poss[1], change = [v], Set([1])
      while !isempty(change)
        new_changed, change = prop_path_eq_info!(S, J, eqclasses, d, changed, eqd, poss, change)
        changed |= new_changed
        if isnothing(change) return changed => true end # FAILED
      end
    end
  end
  return changed => false
end

"""Change = tables that have had information added to them"""
function prop_path_eq_info!(S, J, eq, d, changed, eqd, poss, change
                           )::Tuple{Bool, Union{Nothing,Set{Int}}}
  newchange = Set{Int}()
  for c in change
    for arr_out_ind in incident(eqd, c, :src)
      arr_out, t_ind = eqd[arr_out_ind, :elabel], eqd[arr_out_ind, :tgt]
      ttab = eqd[t_ind, :vlabel]
      as, at = add_srctgt(arr_out)
      if poss[c] ⊆ J[as] # we know the image of this set of values
        tgt_vals = [find_root!(eq[ttab],x)
                    for x in J[vcat(incident(J, poss[c], as)...), at]]
        if !(poss[t_ind] ⊆ tgt_vals)  # we've gained information
          intersect!(poss[t_ind], tgt_vals)
          if isempty(poss[t_ind]) return changed, nothing end
          push!(newchange, t_ind)
          if length(poss[t_ind]) == 1 # we can set FKs into this table
            changed |= set_fks!(S, J, d, eqd, poss, t_ind)
          end
        end
      end
    end
    for arr_in_ind in incident(eqd, c, :tgt)
      arr_in, s_ind = eqd[arr_in_ind, :elabel], eqd[arr_in_ind, :src]
      stab = eqd[s_ind, :vlabel]
      if arr_in ∈ d[2] && stab ∈ d[1] # only can infer backwards if this is true
        as, at = add_srctgt(arr_in)
        src_vals = [find_root!(eq[stab],x)
                    for x in J[vcat(incident(J, poss[c], at)...), as]]
        if !(poss[s_ind] ⊆ src_vals) # gained information
          intersect!(poss[s_ind], src_vals)
          if isempty(poss[s_ind]) return changed, nothing end
          push!(newchange, s_ind)
          if length(poss[s_ind]) == 1 # we can set FKs into this table
            changed |= set_fks!(S, J, d, eqd, poss, s_ind)
          end
        end
      end
    end
  end
  return changed, newchange
end

"""Helper for prop_path_eq_info"""
function set_fks!(S, J, d, eqd, poss, t_ind)::Bool
  changed = false
  for e_ind in incident(eqd, t_ind, :src)
    e, tgt_ind = eqd[e_ind, :elabel], eqd[e_ind, :tgt]
    if length(poss[tgt_ind]) == 1
      x, y= only(poss[t_ind]), only(poss[tgt_ind])
      if !has_map(J, e, x, y)
        add_rel!(S, J, d, e, x, y)
        changed = true
      end
    end
  end
  for e_ind in incident(eqd, t_ind, :tgt)
    e, src_ind = eqd[e_ind, :elabel], eqd[e_ind, :src]
    if length(poss[src_ind]) == 1
      x, y = only(poss[src_ind]), only(poss[t_ind])
      if !has_map(J, e, x, y)
        add_rel!(S, J, d, e, x, y)
        changed = true
      end
    end
  end
  return changed
end


# Misc
######

"""
1. Enumerate elements of ℕᵏ for an underlying graph with k nodes.
2. For each of these: (c₁, ..., cₖ) create a term model with that many constants

Do the first enumeration by incrementing n_nonzero and finding partitions so
that ∑(c₁,...) = n_nonzero

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

# Branching decision logic
##########################
"""
Branch priority - this is an art b/c patheqs & cones are two incommensurate ways
that a piece of information could be useful. We'll prioritize cones:
1. Defined->Defined AND in the diagram of (co)cones: weigh by # of (co)cones
2. Cocone orphan - order to minimize legs to undefined and then minimize legs
3. Defined->Undefined AND in the diagram of (co)cones
4. Defined -> Defined (no cone, weigh by # of path eqs)
5: Defined->Undefined (no cone, weigh by # of path eqs)
6: Undefined -> Defined (weigh by path eqs)
7: Undefined -> Undefined (weigh by path eqs)
"""
function priority(S::Sketch, d::Defined, cco::Vector{Symbol}
                 )::Union{Nothing, Symbol}
  dobs, dhoms = d
  udobs = setdiff(S.schema[:vlabel], dobs)
  ls = limit_scores(S, d)
  hs = (a,b) ->  [(h, hom_score(S,ls, h)) for h in hom_set(S,a,b) if h ∉ dhoms]
  hdd = hs(dobs,dobs)
  hddl = collect(filter(x->x[2][1]>0, hdd))
  if !isempty(hddl)
    return first(last(sort(hddl, by=x->x[2][1]))) # CASE 1
  elseif !isempty(cco)
    return first(sort(cco, by=cocone_score(S, d))) # CASE 2
  end
  hdu =hs(dobs,udobs)
  hudl = collect(filter(x -> x[2][1] > 0, hdd))
  if !isempty(hudl)
    return first(last(sort(hudl, by=x->x[2][1]))) # CASE 3
  elseif !isempty(hdd)
    return first(last(sort(hdd, by=x->x[2][2]))) # CASE 4
  elseif !isempty(hdu)
    return first(last(sort(hdu, by=x->x[2][2]))) # CASE 5
  end
  hud = hs(udobs,dobs)
  if !isempty(hud)
    return first(last(sort(hud, by=x->x[2][2]))) # CASE 6
  end
  huu = hs(udobs,udobs)
  if !isempty(huu)
    return first(last(sort(huu, by=x->x[2][2]))) # CASE 7
  end
  return nothing
end

"""minimize (legs w/ undefined tgts, undefined legs, total # of legs)"""
function cocone_score(S::Sketch, d::Defined)::Function
  function f(c::Symbol)::Tuple{Int,Int,Int}
    cc = only([cc for cc in S.cocones if cc.apex == c])
    srcs = filter(z->z ∉ d[1], [cc.d[x, :vlabel] for x in first.(cc.legs)])
    (length(srcs),length(filter(l->l ∉d[2], cc.legs)),length(cc.legs))
  end
  return f
end

hom_score(S::Sketch, ls::Dict{Symbol, Int}, h::Symbol) = (
  limit_score(S,ls,h), eq_score(S,h))

eq_score(S::Sketch, h::Symbol) = sum([count(==(h), d[:elabel]) for d in S.eqs])

"""
Evaluate the desirability of knowing more about a hom based on limit
 definedness. Has precomputed desirability of each limit as an argument.
"""
limit_score(S::Sketch,ls::Dict{Symbol, Int},h::Symbol) = sum(
  [ls[c.apex] for c in vcat(S.cones, S.cocones) if h ∈ c.d[:elabel]])
"""Give each undefined limit object a score for how undefined it is:"""
limit_scores(S::Sketch, d::Defined) = Dict([c.apex=>limit_obj_definedness(d,c)
                                for c in vcat(S.cones,S.cocones)])
"""
Evaluate undefinedness of a limit object:
  (# of undefined objs, # of undefined homs)
We should focus on resolving morphisms of almost-defined limit objects, so we
give a high score to something with a little bit missing, low score to things
with lots missing, and zero to things that are fully defined.
"""
function limit_obj_definedness(d::Defined, c::Cone)::Int
  dob, dhom = d
  udob, udhom = setdiff(Set(c.d[:vlabel]), dob), setdiff(Set(c.d[:elabel]), dhom)
  if isempty(vcat(udob,udhom)) return typemin(Int)
  else
    return -(100*length(udob) + length(udhom))
  end
end
end # module