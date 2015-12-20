
util = require 'util'
assert = require 'assert'
dumbjs = require 'dumbjs/index'
bindifyPrelude = require 'dumbjs/lib/bindify-prelude'
tern = require 'tern/lib/infer'
estraverse = require 'estraverse'
es = require 'event-stream'

{ format } = require('./lib/format')
{ gen } = require('./lib/gen')
run_transforms = require('./transforms/index')
{ make_fake_class } = require './lib/fake-classes'
cpp_types = require './lib/cpp-types'

# Annotate the AST with "func_at", "scope_at", "" properties which tell us what function a tree node belongs to
annotate = (ast) ->
    fun_stack = []
    var_stack = []
    scope_stack = [tern.cx().topScope]
    cur_fun = () -> fun_stack[fun_stack.length - 1]
    cur_var = () -> var_stack[var_stack.length - 1]
    cur_scope = () -> scope_stack[scope_stack.length - 1]
    unroll_member_expression_into_array = (membex) ->
        if membex.object.type is 'MemberExpression'
            return unroll_member_expression_into_array(membex.object).concat([membex.property])
        else if membex.object.type is 'Identifier'
            return [membex.object, membex.property]
        else
            throw 'impossible'

    member_expression_kind = (membex) ->
        try
            identifiers = unroll_member_expression_into_array(membex)
        catch e
            if e is 'impossible'
                return
            throw e

        return identifiers.reduce((accum, ident) ->
            if accum is undefined
                return undefined
            prop = accum.hasProp(
                if ident.type is 'Identifier' then ident.name else '<i>'
            )?.getType(false)
            return prop or undefined
        , cur_scope())
    estraverse.traverse ast,
        enter: (node, parent) ->
            node.func_at = cur_fun()
            Object.defineProperty node, 'parent',
                enumerable: false, get: () -> parent
            node.scope_at = cur_scope()
            node.cur_var = cur_var()
            if node.type is 'VariableDeclaration'
                var_stack.push node
            if node.type is 'FunctionDeclaration' or
                    node.type is 'FunctionExpression'
                fun_stack.push node
                scope_stack.push(node.scope or node.body.scope or cur_scope())
                node.closure = cur_scope()

            if node.type is 'Identifier' and
                    parent isnt cur_fun() and
                    not (parent.type is 'MemberExpression' and parent.property is node)
                prop = cur_scope().hasProp(node.name)
                if prop
                    type = prop.getType(false)
                    assert type, 'Couldn\'t statically determine the type of ' + node.name
                    node.kind = type

            if node.type is 'MemberExpression'
                node.kind = member_expression_kind(node)

            return node
        leave: (node) ->
            if node.type is 'VariableDeclaration'
                var_stack.pop()
            if node.type in ['FunctionExpression', 'FunctionDeclaration']
                fun_stack.pop()
                scope_stack.pop()
    return ast

# Flatten things which are expressions in JS, but statements in C
flatten = (ast) ->
    counter = 0
    gen_name = () -> 'flatten_' + counter++
    current_function = () -> fnstack[fnstack.length - 1]
    fnstack = []

    put_in_function = (node, {is_func, global_ok, name} = {}) ->
        insertion = node.func_at?.body
        if (not insertion) and global_ok
            insertion = ast
        generated_name = name or gen_name()
        if not is_func
            decl =
                type: "VariableDeclaration",
                kind: 'var'
                declarations: [
                    type: "VariableDeclarator",
                    id: type: "Identifier", name: generated_name
                    init: node ]
        else
            decl = node
            decl.type = 'FunctionDeclaration'
            decl.id = { type: 'Identifier', name: generated_name }
        insertion.body.unshift decl
        return { type: 'Identifier', name: generated_name }

    estraverse.replace ast,
        leave: (node, parent) ->
            if node.type is 'VariableDeclaration'
                the_var = node
                the_func = null
                estraverse.traverse node, enter: (node, parent) ->
                    if node.type in ["FunctionExpression", "FunctionDeclaration"] and
                            parent.parent is the_var
                        assert not the_func, '(SANITY) two functions are direct children of this var statement? wtfmen'
                        the_func = node

                if the_func
                    the_func.type = 'FunctionDeclaration'
                    the_func.id = the_var.declarations[0].id

                return the_func if the_func


# Cleanup
cleanup = (ast) ->
    estraverse.replace ast, enter: (node) ->
        # Gotta remove expression statements cos they be banned in C!
        if node.type is 'ExpressionStatement' and
                node.expression.type is 'Literal'
            return estraverse.VisitorOption.Remove

        if node.type is 'VariableDeclaration'
            assert node.declarations.length is 1
            if node.declarations[0].init?.type is 'FunctionExpression'
                return {
                    type: 'FunctionDeclaration',
                    id: node.declarations[0].id,
                    body: node.declarations[0].init.body,
                    params: node.declarations[0].init.params,
                }

tell_tern_about_bind = (ctx) ->
    topScope = ctx.topScope

    bindProp = topScope.defProp('BIND')
    bindFunc = new tern.Fn(
        'BIND',      # fname
        tern.ANull,  # this
        [], # arguments. No arguments, hope that's ok with tern.
        [],
        new tern.Fn()  # the return type
    )
    bindProp.addType(bindFunc)

    bindFunc.computeRet = (_self, [funcType, closureType], [funcNode, closureNode]) ->
        funcType = funcType.getType(false)
        closureType = closureType.getType(false)
        funcType.args[0].addType(closureType)
        assert funcType and closureType, 'call to BIND not made with predictable arguments!'

        newFuncType = new tern.Fn(
            'boundFn('+funcType.name+')',
            tern.ANull,
            funcType.args.slice(1),
            funcType.argNames.slice(1),
            funcType.retval
        )

        newFuncType.original = funcType

        return newFuncType


# deal with dumbjs's bindify
bindify = (ast) ->
    current_function = null
    estraverse.replace ast, enter: (node, parent) ->
        if node.type is 'CallExpression' and node.callee.name is 'BIND'
            assert node.arguments.length is 2
            assert node.arguments[0].kind, "couldn\'t stactically determine the type of #{gen format node.arguments[0]}"
            funcType = node.arguments[0].kind
            if funcType.original
                funcType = funcType.original
            functions_that_need_bind.push(funcType)
            return {
                type: 'NewExpression',
                callee: node.arguments[0],
                arguments: node.arguments.slice(1),
                scope_at: node.scope_at,
                func_at: node.func_at,
            }

global.to_put_before = undefined
global.functions_that_need_bind = undefined
module.exports = (js) ->
    ctx = new tern.Context
    tern.withContext ctx, () ->
        global.to_put_before = []
        global.functions_that_need_bind = []
        js = dumbjs(js)
        tell_tern_about_bind(ctx)
        ast = tern.parse(js)
        ast = cleanup ast
        tern.analyze ast
        annotate ast
        ast = bindify ast
        ast = cpp_types ast
        run_transforms(ast)
        pseudo_c_ast = format ast
        before_c = (global.to_put_before.join '\n') + '\n\n'
        c = gen(pseudo_c_ast)
        return before_c + c


