local ast = require "titan-compiler.ast"
local checker = require "titan-compiler.checker"
local util = require "titan-compiler.util"
local pretty = require "titan-compiler.pretty"
local types = require "titan-compiler.types"

local coder = {}

local generate_program
local generate_stat
local generate_var
local generate_exp

function coder.generate(filename, input, modname)
    local prog, errors = checker.check(filename, input)
    if not prog then return false, errors end
    local code = generate_program(prog, modname)
    return code, errors
end

local whole_file_template = [[
/* This file was generated by the Titan compiler. Do not edit by hand */
/* Indentation and formatting courtesy of titan-compiler/pretty.lua */

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include "lapi.h"
#include "lfunc.h"
#include "lgc.h"
#include "lobject.h"
#include "lstate.h"
#include "ltable.h"
#include "lvm.h"

#include "math.h"

${DEFINE_FUNCTIONS}

int init_${MODNAME}(lua_State *L)
{
    ${INITIALIZE_TOPLEVEL}
    return 0;
}

int luaopen_${MODNAME}(lua_State *L)
{
    Table *titan_globals = luaH_new(L);
    luaH_resizearray(L, titan_globals, ${N_TOPLEVEL});

    {
        CClosure *func = luaF_newCclosure(L, 1);
        func->f = init_${MODNAME};
        sethvalue(L, &func->upvalue[0], titan_globals);
        setclCvalue(L, L->top, func);
        api_incr_top(L);

        lua_call(L, 0, 0);
    }

    ${CREATE_MODULE_TABLE}
    return 1;
}
]]

--
-- C syntax
--

-- Technically, we only need to escape the quote and backslash
-- But quoting some extra things helps readability...
local some_c_escape_sequences = {
    ["\\"] = "\\\\",
    ["\""] = "\\\"",
    ["\a"] = "\\a",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
    ["\v"] = "\\v",
}

local function c_string(s)
    return '"' .. (s:gsub('.', some_c_escape_sequences)) .. '"'
end

local function c_integer(n)
    return string.format("%i", n)
end

local function c_boolean(b)
    if b then
        return c_integer(1)
    else
        return c_integer(0)
    end
end

local function c_float(n)
    return string.format("%f", n)
end

-- @param ctype: (string) C datatype, as produced by ctype()
-- @param varname: (string) C variable name
-- @returns A syntactically valid variable declaration
local function c_declaration(ctyp, varname)
    -- This would be harder if we also allowed array or function pointers...
    return ctyp .. " " .. varname
end

--
--
--

-- This name-mangling scheme is designed to avoid clashes between the function
-- names created in separate models.
local function mangle_function_name(_modname, funcname, kind)
    return string.format("function_%s_%s", funcname, kind)
end

local function local_name(varname)
    return string.format("local_%s", varname)
end

-- @param type Type of the titan value
-- @returns type of the corresponding C variable
--
-- We currently represent C types as strings. This suffices for primitive types
-- and pointers to primitive types but we might need to switch to a full ADT if
-- we decide to also support array and function pointer types.
local function ctype(typ)
    local tag = typ._tag
    if     tag == types.T.Nil      then return "int"
    elseif tag == types.T.Boolean  then return "int"
    elseif tag == types.T.Integer  then return "lua_Integer"
    elseif tag == types.T.Float    then return "lua_Number"
    elseif tag == types.T.String   then return "TString *"
    elseif tag == types.T.Function then error("not implemented yet")
    elseif tag == types.T.Array    then return "Table *"
    elseif tag == types.T.Record   then error("not implemented yet")
    else error("impossible")
    end
end

local function get_slot(typ, src_slot_address)
    local tmpl
    local tag = typ._tag
    if     tag == types.T.Nil      then tmpl = "0"
    elseif tag == types.T.Boolean  then tmpl = "bvalue(${SRC})"
    elseif tag == types.T.Integer  then tmpl = "ivalue(${SRC})"
    elseif tag == types.T.Float    then tmpl = "fltvalue(${SRC})"
    elseif tag == types.T.String   then tmpl = "tsvalue(${SRC})"
    elseif tag == types.T.Function then error("not implemented")
    elseif tag == types.T.Array    then tmpl = "hvalue(${SRC})"
    elseif tag == types.T.Record   then error("not implemented")
    else error("impossible")
    end
    return util.render(tmpl, {SRC = src_slot_address})
end


local function set_slot(typ, dst_slot_address, value)
    local tmpl
    local tag = typ._tag
    if     tag == types.T.Nil      then tmpl = "setnilvalue(${DST});"
    elseif tag == types.T.Boolean  then tmpl = "setbvalue(${DST}, ${SRC});"
    elseif tag == types.T.Integer  then tmpl = "setivalue(${DST}, ${SRC});"
    elseif tag == types.T.Float    then tmpl = "setfltvalue(${DST}, ${SRC});"
    elseif tag == types.T.String   then tmpl = "setsvalue(L, ${DST}, ${SRC});"
    elseif tag == types.T.Function then error("not implemented yet")
    elseif tag == types.T.Array    then tmpl = "sethvalue(L, ${DST}, ${SRC});"
    elseif tag == types.T.Record   then error("not implemented yet")
    else error("impossible")
    end
    return util.render(tmpl, { DST = dst_slot_address, SRC = value })
end

local function toplevel_is_value_declaration(tl_node)
    local tag = tl_node._tag
    if     tag == ast.Toplevel.Func then
        return true
    elseif tag == ast.Toplevel.Var then
        return true
    elseif tag == ast.Toplevel.Record then
        return false
    elseif tag == ast.Toplevel.Import then
        return false
    else
        error("impossible")
    end
end

-- @param prog: (ast) Annotated AST for the whole module
-- @param modname: (string) Lua module name (for luaopen)
-- @return (string) C code for the whole module
generate_program = function(prog, modname)

    -- Find where each global variable gets stored in the global table
    local n_toplevel = 0
    do
        for _, tl_node in ipairs(prog) do
            if toplevel_is_value_declaration(tl_node) then
                tl_node._global_index = n_toplevel
                n_toplevel = n_toplevel + 1
            end
        end
    end

    -- Create toplevel function declarations
    local define_functions
    do
        local function_definitions = {}
        for _, tl_node in ipairs(prog) do
            if tl_node._tag == ast.Toplevel.Func then
                -- Titan entry point
                local titan_entry_point_name =
                    mangle_function_name(modname, tl_node.name, "titan")

                assert(#tl_node._type.rettypes == 1)
                local ret_ctype = ctype(tl_node._type.rettypes[1])

                local args = {}
                table.insert(args, [[lua_State * L]])
                for _, param in ipairs(tl_node.params) do
                    local name = param.name
                    local typ  = param._type
                    table.insert(args,
                        c_declaration(ctype(typ), local_name(name)))
                end

                table.insert(function_definitions,
                    util.render([[
                        static ${RET} ${NAME}(${ARGS})
                        ${BODY}
                    ]], {
                        RET = ret_ctype,
                        NAME = titan_entry_point_name,
                        ARGS = table.concat(args, ", "),
                        BODY = generate_stat(tl_node.block)
                    })
                )

                -- Lua entry point
                local lua_entry_point_name =
                    mangle_function_name(modname, tl_node.name, "lua")

                assert(#tl_node._type.rettypes == 1)
                local ret_typ = tl_node._type.rettypes[1]

                local args = {}
                table.insert(args, [[L]])
                for i, param in ipairs(tl_node.params) do
                    local slot = util.render([[L->ci->func + ${I}]], {
                        I = c_integer(i)
                    })
                    table.insert(args, get_slot(param._type, slot))
                end

                table.insert(function_definitions,
                    util.render([[
                        static int ${LUA_ENTRY_POINT}(lua_State *L)
                        {
                            ${RET_DECL} = ${TITAN_ENTRY_POINT}(${ARGS});
                            ${SET_RET}
                            api_incr_top(L);
                            return 1;
                        }
                    ]], {
                        LUA_ENTRY_POINT = lua_entry_point_name,
                        TITAN_ENTRY_POINT = titan_entry_point_name,
                        RET_DECL = c_declaration(ctype(ret_typ), "ret"),
                        ARGS = table.concat(args, ", "),
                        SET_RET = set_slot(ret_typ, "L->top", "ret"),
                    })
                )

                --
                tl_node._titan_entry_point = titan_entry_point_name
                tl_node._lua_entry_point = lua_entry_point_name
            end
        end
        define_functions = table.concat(function_definitions, "\n")
    end

    -- Construct the values in the toplevel
    -- This needs to happen inside a C closure with all the same upvalues that
    -- a titan function has, because the initializer expressions might rely on
    -- that.
    local initialize_toplevel
    do
        local parts = {}

        if n_toplevel > 0 then
            table.insert(parts,
                [[Table *titan_globals = hvalue(&clCvalue(L->ci->func)->upvalue[0]);]])
        end

        for _, tl_node in ipairs(prog) do
            if tl_node._global_index then
                local arr_slot = util.render([[ &titan_globals->array[${I}] ]], {
                    I = c_integer(tl_node._global_index)
                })

                local tag = tl_node._tag
                if     tag == ast.Toplevel.Func then
                    table.insert(parts,
                        util.render([[
                            {
                                CClosure *func = luaF_newCclosure(L, 1);
                                func->f = ${LUA_ENTRY_POINT};
                                sethvalue(L, &func->upvalue[0], titan_globals);
                                setclCvalue(L, ${ARR_SLOT}, func);
                            }
                        ]],{
                            LUA_ENTRY_POINT = tl_node._lua_entry_point,
                            TITAN_ENTRY_POINT = tl_node._titan_entry_point,
                            ARR_SLOT = arr_slot,
                        })
                    )
                elseif tag == ast.Toplevel.Var then
                    local exp = tl_node.value
                    local cstats, cvalue = generate_exp(exp)
                    table.insert(parts, cstats)
                    table.insert(parts, set_slot(exp._type, arr_slot, cvalue))
                else
                    error("impossible")
                end
            end
        end

        initialize_toplevel = table.concat(parts, "\n")
    end

    local create_module_table
    do

        local n_exported_functions = 0
        local parts = {}
        for _, tl_node in ipairs(prog) do
            if tl_node._tag == ast.Toplevel.Func and not tl_node.islocal then
                n_exported_functions = n_exported_functions + 1
                table.insert(parts,
                    util.render([[
                        lua_pushstring(L, ${NAME});
                        setobj(L, L->top, &titan_globals->array[${I}]); api_incr_top(L);
                        lua_settable(L, -3);
                    ]], {
                        NAME = c_string(ast.toplevel_name(tl_node)),
                        I = c_integer(tl_node._global_index)
                    })
                )
            end
        end

        create_module_table = util.render([[
            {
                /* Initialize module table */
                lua_createtable(L, 0, ${N});
                ${PARTS}
            }
        ]], {
            N = c_integer(n_exported_functions),
            PARTS = table.concat(parts, "\n")
        })
    end

    local code = util.render(whole_file_template, {
        MODNAME = modname,
        N_TOPLEVEL = c_integer(n_toplevel),
        DEFINE_FUNCTIONS = define_functions,
        INITIALIZE_TOPLEVEL = initialize_toplevel,
        CREATE_MODULE_TABLE = create_module_table,
    })
    return pretty.reindent_c(code)
end

-- @param stat: (ast.Stat)
-- @return (string) C statements
generate_stat = function(stat)
    local tag = stat._tag
    if     tag == ast.Stat.Block then
        local cstatss = {}
        table.insert(cstatss, "{")
        for _, inner_stat in ipairs(stat.stats) do
            local cstats = generate_stat(inner_stat)
            table.insert(cstatss, cstats)
        end
        table.insert(cstatss, "}")
        return table.concat(cstatss, "\n")

    elseif tag == ast.Stat.While then
        local cond_cstats, cond_cvalue = generate_exp(stat.condition)
        local block_cstats = generate_stat(stat.block)
        return util.render([[
            for(;;) {
                ${COND_STATS}
                if (!(${COND})) break;
                ${BLOCK}
            }
        ]], {
            COND_STATS = cond_cstats,
            COND = cond_cvalue,
            CLOCK = block_cstats
        })

    elseif tag == ast.Stat.Repeat then
        error("not implemented yet")

    elseif tag == ast.Stat.If then
        local cstats
        if stat.elsestat then
            cstats = generate_stat(stat.elsestat)
        else
            cstats = nil
        end

        for i = #stat.thens, 1, -1 do
            local then_ = stat.thens[i]
            local cond_cstats, cond_cvalue = generate_exp(then_.condition)
            local block_cstats = generate_stat(then_.block)
            local else_ = (cstats and "else "..cstats or "")
            if cond_cstats == "" then
                cstats = util.render(
                    [[if (${COND}) ${BLOCK} ${ELSE}]], {
                    COND = cond_cvalue,
                    BLOCK = block_cstats,
                    ELSE = else_
                })
            else
                cstats = util.render(
                    [[{
                        ${STATS}
                        if (${COND}) ${BLOCK} ${ELSE}
                    }]], {
                    STATS = cond_cstats,
                    COND = cond_cvalue,
                    BLOCK = block_cstats,
                    ELSE = else_
                })
            end
        end

        return cstats

    elseif tag == ast.Stat.For then
        local typ = stat.decl._type
        local start_cstats, start_cvalue = generate_exp(stat.start)
        local finish_cstats, finish_cvalue = generate_exp(stat.finish)
        local inc_cstats, inc_cvalue = generate_exp(stat.inc)
        local block_cstats = generate_stat(stat.block)

        -- TODO: remove ternary operator when step is a constant
        local loop_cond = [[(_inc >= 0 ? _start <= _finish : _start >= _finish)]]

        local loop_step
        if typ._tag == types.T.Integer then
            loop_step = [[_start = intop(+, _start, _inc);]]
        elseif typ._tag == types.T.Float then
            loop_step = [[_start = _start + _inc;]]
        else
            error("impossible")
        end

        return util.render([[
            {
                ${START_STAT}
                ${START_DECL} = ${START_VALUE};
                ${FINISH_STAT}
                ${FINISH_DECL} = ${FINISH_VALUE};
                ${INC_STAT}
                ${INC_DECL} = ${INC_VALUE};
                while (${LOOP_COND}) {
                    ${LOOP_DECL} = _start;
                    ${BLOCK}
                    ${LOOP_STEP}
                }
            }
        ]], {
            START_STAT  = start_cstats,
            START_VALUE = start_cvalue,
            START_DECL  = c_declaration(ctype(typ), "_start"),
            FINISH_STAT  = finish_cstats,
            FINISH_VALUE = finish_cvalue,
            FINISH_DECL  = c_declaration(ctype(typ), "_finish"),
            INC_STAT  = inc_cstats,
            INC_VALUE = inc_cvalue,
            INC_DECL  = c_declaration(ctype(typ), "_inc"),
            LOOP_COND = loop_cond,
            LOOP_STEP = loop_step,
            LOOP_DECL = c_declaration(ctype(typ), local_name(stat.decl.name)),
            BLOCK = block_cstats,
        })

    elseif tag == ast.Stat.Assign then
        local var_cstats, var_c_lvalue = generate_var(stat.var)
        local exp_cstats, exp_cvalue = generate_exp(stat.exp)
        return util.render([[
            ${VAR_STATS}
            ${EXP_STATS}
            ${LVALUE} = ${RVALUE};
        ]], {
            VAR_STATS = var_cstats,
            EXP_STATS = exp_cstats,
            LVALUE = var_c_lvalue,
            RVALUE = exp_cvalue
        })

    elseif tag == ast.Stat.Decl then
        local exp_cstats, exp_cvalue = generate_exp(stat.exp)
        local ctyp = ctype(stat.decl._type)
        local varname = local_name(stat.decl.name)
        local declaration = c_declaration(ctyp, varname)
        return util.render([[
            ${STATS}
            ${DECLARATION} = ${VALUE};
        ]], {
            STATS = exp_cstats,
            VALUE = exp_cvalue,
            DECLARATION = declaration,
        })

    elseif tag == ast.Stat.Call then
        error("not implemented yet")

    elseif tag == ast.Stat.Return then
        local cstats, cvalue = generate_exp(stat.exp)
        return util.render([[
            ${CSTATS}
            return ${CVALUE};
        ]], {
            CSTATS = cstats,
            CVALUE = cvalue
        })

    else
        error("impossible")
    end
end

-- @param var: (ast.Var)
-- @returns (string, string) C Statements, and a C lvalue
--
-- The lvalue should not not contain side-effects. Anything that could care
-- about evaluation order should be returned as part of the first argument.
--
-- TODO: Rethink what this function should return once we add arrays and
-- records (the "lvalue" might be a slot, which requires setting a tag when
-- writing to it)
generate_var = function(var)
    local tag = var._tag
    if     tag == ast.Var.Name then
        local decl = var._decl
        if    decl._tag == ast.Decl.Decl then
            -- Local variable
            return "", local_name(decl.name)

        elseif decl._tag == ast.Toplevel.Var then
            -- Toplevel variable
            error("not implemented yet")

        elseif decl._tag == ast.Toplevel.Func then
            -- Toplevel function
            error("not implemented yet")

        else
            error("impossible")
        end

    elseif tag == ast.Var.Bracket then
        error("not implemented yet")

    elseif tag == ast.Var.Dot then
        error("not implemented yet")

    else
        error("impossible")
    end
end

-- @param exp: (ast.Exp)
-- @returns (string, string) C statements, C rvalue
--
-- The rvalue should not not contain side-effects. Anything that could care
-- about evaluation order should be returned as part of the first argument.
generate_exp = function(exp) -- TODO
    local tag = exp._tag
    if     tag == ast.Exp.Nil then
        return "", c_integer(0)

    elseif tag == ast.Exp.Bool then
        return "", c_boolean(exp.value)

    elseif tag == ast.Exp.Integer then
        return "", c_integer(exp.value)

    elseif tag == ast.Exp.Float then
        return "", c_float(exp.value)

    elseif tag == ast.Exp.String then
        error("not implemented yet")

    elseif tag == ast.Exp.Initlist then
        error("not implemented yet")

    elseif tag == ast.Exp.Call then
        error("not implemented yet")

    elseif tag == ast.Exp.Var then
        return generate_var(exp.var)

    elseif tag == ast.Exp.Unop then
        local cstats, cvalue = generate_exp(exp.exp)

        local op = exp.op
        if op == "#" then
            error("not implemented yet")

        elseif op == "-" then
            return cstats, "(".."-"..cvalue..")"

        elseif op == "~" then
            return cstats, "(".."~"..cvalue..")"

        elseif op == "not" then
            return cstats, "(".."!"..cvalue..")"

        else
            error("impossible")
        end

    elseif tag == ast.Exp.Concat then
        error("not implemented yet")

    elseif tag == ast.Exp.Binop then
        local lhs_cstats, lhs_cvalue = generate_exp(exp.lhs)
        local rhs_cstats, rhs_cvalue = generate_exp(exp.rhs)

        -- Lua's arithmetic and bitwise operations for integers happen with
        -- unsigned integers, to ensure 2's compliment behavior and avoid
        -- undefined behavior.
        local function intop(op)
            local cstats = lhs_cstats..rhs_cstats
            local cvalue = util.render("intop(${OP}, ${LHS}, ${RHS})", {
                OP=op, LHS=lhs_cvalue, RHS=rhs_cvalue })
            return cstats, cvalue
        end

        -- Relational operators, and basic float operations don't convert their
        -- parameters
        local function binop(op)
            local cstats = lhs_cstats..rhs_cstats
            local cvalue = util.render("((${LHS})${OP}(${RHS}))", {
                OP=op, LHS=lhs_cvalue, RHS=rhs_cvalue })
            return cstats, cvalue
        end

        local ltyp = exp.lhs._type._tag
        local rtyp = exp.rhs._type._tag

        local op = exp.op
        if     op == "+" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("+")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("+")
            else
                error("impossible")
            end

        elseif op == "-" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("-")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("-")
            else
                error("impossible")
            end

        elseif op == "*" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("*")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("*")
            else
                error("impossible")
            end

        elseif op == "/" then
            if     ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("/")
            else
                error("impossible")
            end

        elseif op == "&" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("&")
            else
                error("impossible")
            end

        elseif op == "|" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("|")
            else
                error("impossible")
            end

        elseif op == "~" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop("^")
            else
                error("impossible")
            end

        elseif op == "<<" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop(">>")
            else
                error("impossible")
            end

        elseif op == ">>" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return intop(">>")
            else
                error("impossible")
            end

        elseif op == "%" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("luaV_mod(L, ${LHS}, ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                -- see luai_nummod
                error("not implemented yet")

            else
                error("impossible")
            end

        elseif op == "//" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("luaV_div(L, ${LHS}, ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                -- see luai_numidiv
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("floor(${LHS} / ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            else
                error("impossible")
            end

        elseif op == "^" then
            if     ltyp == types.T.Float and rtyp == types.T.Float then
                -- see luai_numpow
                local cstats = lhs_cstats..rhs_cstats
                local cvalue = util.render("pow(${LHS}, ${RHS})", {
                    LHS=lhs_cvalue, RHS=rhs_cvalue })
                return cstats, cvalue

            else
                error("impossible")
            end

        elseif op == "==" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("==")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("==")
            else
                error("not implemented yet")
            end

        elseif op == "~=" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("!=")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("!=")
            else
                error("not implemented yet")
            end

        elseif op == "<" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("<")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("<")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet")
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet")
            else
                error("impossible")
            end

        elseif op == ">" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop(">")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop(">")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet")
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet")
            else
                error("impossible")
            end

        elseif op == "<=" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop("<=")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop("<=")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet")
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet")
            else
                error("impossible")
            end

        elseif op == ">=" then
            if     ltyp == types.T.Integer and rtyp == types.T.Integer then
                return binop(">=")
            elseif ltyp == types.T.Float and rtyp == types.T.Float then
                return binop(">=")
            elseif ltyp == types.T.String and rtyp == types.T.String then
                error("not implemented yet")
            elseif ltyp == types.T.Integer and rtyp == types.T.Float then
                error("not implemented yet")
            elseif ltyp == types.T.Float and rtyp == types.T.Integer then
                error("not implemented yet")
            else
                error("impossible")
            end

        elseif op == "and" then
            if     ltyp == types.T.Boolean and rtyp == types.T.Boolean then
                error("not implemented yet")
            else
                error("impossible")
            end

        elseif op == "or" then
            if     ltyp == types.T.Boolean and rtyp == types.T.Boolean then
                error("not implemented yet")
            else
                error("impossible")
            end

        else
            error("not implemented yet")
        end

    elseif tag == ast.Exp.Cast then
        local cstats, cvalue = generate_exp(exp.exp)

        local src_typ = exp.exp._type
        local dst_typ = exp._type

        if     src_typ._tag == dst_typ._tag then
            return cstats, cvalue

        elseif src_typ._tag == types.T.Integer and dst_typ._tag == types.T.Float then
            return cstats, "((lua_Number)"..cvalue..")"

        elseif src_typ._tag == types.T.Float and dst_typ._tag == types.T.Integer then
            error("not implemented yet")

        else
            error("impossible")
        end

    else
        error("impossible")
    end
end

return coder
