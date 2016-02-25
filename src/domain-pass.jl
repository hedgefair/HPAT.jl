module DomainPass


# ENTRY to distributedIR
function from_root(function_name, ast :: Expr)
    @assert ast.head == :lambda "Input to DomainPass should be :lambda Expr"
    @dprintln(1,"Starting main DomainPass.from_root.  function = ", function_name, " ast = ", ast)

    linfo = CompilerTools.LambdaHandling.lambdaExprToLambdaVarInfo(ast)
    state::DomainState = DomainState(linfo, 0)
    
    # transform body
    @assert ast.args[3].head==:body "DomainPass: invalid lambda input"
    body = TypedExpr(ast.args[3].typ, :body, from_toplevel_body(ast.args[3].args, state)...)
    new_ast = CompilerTools.LambdaHandling.LambdaVarInfoToLambdaExpr(state.LambdaVarInfo, body)
    @dprintln(1,"DomainPass.from_root returns function = ", function_name, " ast = ", new_ast)
    # ast = from_expr(ast)
    return new_ast
end

# information about AST gathered and used in DomainPass
type DomainState
    linfo  :: LambdaVarInfo
    data_source_counter::Int64 # a unique counter for data sources in program 
end


# nodes are :body of AST
function from_toplevel_body(nodes::Array{Any,1}, state::DomainState)
    state.max_label = ParallelIR.getMaxLabel(state.max_label, nodes)
    res::Array{Any,1} = genDistributedInit(state)
    for node in nodes
        new_exprs = from_expr(node, state)
        append!(res, new_exprs)
    end
    return res
end


function from_expr(node::Expr, state::DomainState)
    head = node.head
    if head==:(=)
        return from_assignment(node, state)
    else
        return [node]
    end
end


function from_expr(node::Any, state::DomainState)
    return [node]
end

# :(=) assignment (:(=), lhs, rhs)
function from_assignment(state, env, node::Expr)
    
    # pattern match distributed calls that need domain-ir translation
    matched = pattern_match_hps_dist_calls(state, env, node.args[1], node.args[2])
    # matched is an expression, :not_matched head is used if not matched 
    if matched.head!=:not_matched
        return matched
    else
        return [node]
    end
end

function pattern_match_hps_dist_calls(state, env, lhs::SymGen, rhs::Expr)
    # example of data source call: 
    # :((top(typeassert))((top(convert))(Array{Float64,1},(ParallelAccelerator.API.__hps_data_source_HDF5)("/labels","./test.hdf5")),Array{Float64,1})::Array{Float64,1})
    if rhs.head==:call && length(rhs.args)>=2 && isCall(rhs.args[2])
        in_call = rhs.args[2]
        if length(in_call.args)>=3 && isCall(in_call.args[3]) 
            inner_call = in_call.args[3]
            if isa(inner_call.args[1],GlobalRef) && inner_call.args[1].name==:__hps_data_source_HDF5
                dprintln(env,"data source found ", inner_call)
                hdf5_var = inner_call.args[2]
                hdf5_file = inner_call.args[3]
                # update counter and get data source number
                state.data_source_counter += 1
                dsrc_num = state.data_source_counter
                dsrc_id_var = addGenSym(Int64, state.linfo)
                updateDef(state, dsrc_id_var, dsrc_num)
                emitStmt(state, mk_expr(Int64, :(=), dsrc_id_var, dsrc_num))
                # get array type
                arr_typ = getType(lhs, state.linfo)
                dims = ndims(arr_typ)
                elem_typ = eltype(arr_typ)
                # generate open call
                # lhs is dummy argument so ParallelIR wouldn't reorder
                open_call = mk_call(:__hps_data_source_HDF5_open, [dsrc_id_var, hdf5_var, hdf5_file, lhs])
                emitStmt(state, open_call)
                # generate array size call
                # arr_size_var = addGenSym(Tuple, state.linfo)
                # assume 1D for now
                arr_size_var = addGenSym(H5SizeArr_t, state.linfo)
                size_call = mk_call(:__hps_data_source_HDF5_size, [dsrc_id_var, lhs])
                updateDef(state, arr_size_var, size_call)
                emitStmt(state, mk_expr(arr_size_var, :(=), arr_size_var, size_call))
                # generate array allocation
                size_expr = Any[]
                for i in dims:-1:1
                    size_i = addGenSym(Int64, state.linfo)
                    size_i_call = mk_call(:__hps_get_H5_dim_size, [arr_size_var, i])
                    updateDef(state, size_i, size_i_call)
                    emitStmt(state, mk_expr(Int64, :(=), size_i, size_i_call))
                    push!(size_expr, size_i)
                end
                arrdef = type_expr(arr_typ, mk_alloc(state, elem_typ, size_expr))
                updateDef(state, lhs, arrdef)
                emitStmt(state, mk_expr(arr_typ, :(=), lhs, arrdef))
                # generate read call
                read_call = mk_call(:__hps_data_source_HDF5_read, [dsrc_id_var, lhs])
                return read_call
            elseif isa(inner_call.args[1],GlobalRef) && inner_call.args[1].name==:__hps_data_source_TXT
                dprintln(env,"data source found ", inner_call)
                txt_file = inner_call.args[2]
                # update counter and get data source number
                state.data_source_counter += 1
                dsrc_num = state.data_source_counter
                dsrc_id_var = addGenSym(Int64, state.linfo)
                updateDef(state, dsrc_id_var, dsrc_num)
                emitStmt(state, mk_expr(Int64, :(=), dsrc_id_var, dsrc_num))
                # get array type
                arr_typ = getType(lhs, state.linfo)
                dims = ndims(arr_typ)
                elem_typ = eltype(arr_typ)
                # generate open call
                # lhs is dummy argument so ParallelIR wouldn't reorder
                open_call = mk_call(:__hps_data_source_TXT_open, [dsrc_id_var, txt_file, lhs])
                emitStmt(state, open_call)
                # generate array size call
                # arr_size_var = addGenSym(Tuple, state.linfo)
                arr_size_var = addGenSym(SizeArr_t, state.linfo)
                size_call = mk_call(:__hps_data_source_TXT_size, [dsrc_id_var, lhs])
                updateDef(state, arr_size_var, size_call)
                emitStmt(state, mk_expr(arr_size_var, :(=), arr_size_var, size_call))
                # generate array allocation
                size_expr = Any[]
                for i in dims:-1:1
                    size_i = addGenSym(Int64, state.linfo)
                    size_i_call = mk_call(:__hps_get_TXT_dim_size, [arr_size_var, i])
                    updateDef(state, size_i, size_i_call)
                    emitStmt(state, mk_expr(Int64, :(=), size_i, size_i_call))
                    push!(size_expr, size_i)
                end
                arrdef = type_expr(arr_typ, mk_alloc(state, elem_typ, size_expr))
                updateDef(state, lhs, arrdef)
                emitStmt(state, mk_expr(arr_typ, :(=), lhs, arrdef))
                # generate read call
                read_call = mk_call(:__hps_data_source_TXT_read, [dsrc_id_var, lhs])
                return read_call
            elseif isa(inner_call.args[1],GlobalRef) && inner_call.args[1].name==:__hps_kmeans
                dprintln(env,"kmeans found ", inner_call)
                lib_call = mk_call(:__hps_kmeans, [lhs,inner_call.args[2], inner_call.args[3]])
                return lib_call 
            elseif isa(inner_call.args[1],GlobalRef) && inner_call.args[1].name==:__hps_LinearRegression
                dprintln(env,"LinearRegression found ", inner_call)
                lib_call = mk_call(:__hps_LinearRegression, [lhs,inner_call.args[2], inner_call.args[3]])
                return lib_call 
            elseif isa(inner_call.args[1],GlobalRef) && inner_call.args[1].name==:__hps_NaiveBayes
                dprintln(env,"NaiveBayes found ", inner_call)
                lib_call = mk_call(:__hps_NaiveBayes, [lhs,inner_call.args[2], inner_call.args[3], inner_call.args[4]])
                return lib_call 
            end
        end
    end
    
    return Expr(:not_matched)
end

function pattern_match_hps_dist_calls(state, env, lhs::Any, rhs::Any)
    return Expr(:not_matched)
end


end # module

