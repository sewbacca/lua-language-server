local guide   = require 'parser.guide'
local files   = require 'files'
local vm      = require 'vm.vm'
local library = require 'library'
local await   = require 'await'

local STATE_USED  = 1 << 0
local STATE_LOCAL = 1 << 1
local STATE_NODE  = 1 << 2
local STATE_LABEL = 1 << 3

local function markFlag(state, source, flag)
    local flags = state[source] or 0
    if flags & flag ~= 0 then
        return false
    end
    state[source] = flags | flag
    return true
end

local function ofSelf(state, loc, callback)
    -- self 的2个特殊引用位置：
    -- 1. 当前方法定义时的对象（mt）
    local method = loc.method
    local node   = method.node
    vm.refOf(state, node, callback)
    -- 2. 调用该方法时传入的对象
end

local function ofLocal(state, loc, callback)
    if not markFlag(state, loc, STATE_LOCAL) then
        return
    end
    -- 方法中的 self 使用了一个虚拟的定义位置
    if loc.tag ~= 'self' then
        callback(loc, 'declare')
        vm.refOf(state, loc, callback)
    end
    local refs = loc.ref
    if refs then
        for i = 1, #refs do
            local ref = refs[i]
            if ref.type == 'getlocal' then
                callback(ref, 'get')
                vm.refOf(state, ref, callback)
                if loc.tag == '_ENV' then
                    local parent = ref.parent
                    if parent.type == 'getfield'
                    or parent.type == 'getindex' then
                        if guide.getKeyName(parent) == '_G' then
                            callback(parent, 'declare')
                            vm.refOf(state, ref, callback)
                        end
                    end
                end
            elseif ref.type == 'setlocal' then
                callback(ref, 'set')
                vm.refOf(state, ref, callback)
            elseif ref.type == 'getglobal' then
                if loc.tag == '_ENV' then
                    if guide.getName(ref) == '_G' then
                        callback(ref, 'get')
                        vm.refOf(state, ref, callback)
                    end
                end
            end
        end
    end
    if loc.tag == 'self' then
        ofSelf(state, loc, callback)
    end
end

local function ofGlobal(state, source, callback)
    local key = guide.getKeyName(source)
    local node = source.node
    if not markFlag(state, node, STATE_NODE) then
        return
    end
    if node.tag == '_ENV' then
        local uris = files.findGlobals(key)
        for i = 1, #uris do
            local uri = uris[i]
            local ast = files.getAst(uri)
            local globals = vm.getGlobals(ast.ast)
            if globals and globals[key] then
                for _, info in ipairs(globals[key]) do
                    callback(info)
                    vm.refOf(state, info.source, callback)
                end
            end
        end
    else
        -- 重载了 _ENV
        vm.eachField(node, function (info)
            if key == info.key then
                callback(info)
                vm.refOf(state, info.source, callback)
            end
        end)
    end
end

local function ofField(state, source, callback)
    local parent = source.parent
    local key    = guide.getKeyName(source)
    local node
    if parent.type == 'tablefield'
    or parent.type == 'tableindex' then
        node = parent.parent
    else
        node = parent.node
    end
    if not markFlag(state, node, STATE_NODE) then
        return
    end
    vm.eachField(node, function (info)
        if key == info.key then
            callback(info)
            vm.refOf(source, state, callback)
        end
    end)
end

local function ofLabel(state, source, callback)
    if not markFlag(state, source, STATE_LABEL) then
        return
    end
    callback(source, 'set')
    if source.ref then
        for _, ref in ipairs(source.ref) do
            callback(ref, 'get')
        end
    end
end

local function ofGoTo(state, source, callback)
    local name = source[1]
    local label = guide.getLabel(source, name)
    if label then
        ofLabel(state, label, callback)
    end
end

local function ofValue(state, source, callback)
    callback(source, 'value')
end

local function ofIndex(state, source, callback)
    local parent = source.parent
    if not parent then
        return
    end
    if parent.type == 'setindex'
    or parent.type == 'getindex'
    or parent.type == 'tableindex' then
        ofField(state, source, callback)
    end
end

local function ofCallRecv(state, func, index, callback, offset)
    if not markFlag(state, func, STATE_USED) then
        return
    end
    offset = offset or 0
    vm.eachRef(func, function (info)
        local src = info.source
        local returns
        if src.type == 'main' or src.type == 'function' then
            returns = src.returns
        end
        if returns then
            -- 搜索函数第 index 个返回值
            for i = 1, #returns do
                local rtn = returns[i]
                local val = rtn[index-offset]
                if val then
                    vm.refOf(state, val, callback)
                end
            end
        end
    end)
end

local function ofSpecialCallRecv(state, call, func, index, callback, offset)
    local name = func.special
    offset = offset or 0
    if name == 'setmetatable' then
        if index == 1 + offset then
            local args = call.args
            if args[1+offset] then
                vm.refOf(state, args[1+offset], callback)
            end
            if args[2+offset] then
                vm.eachField(args[2+offset], function (info)
                    if info.key == 's|__index' then
                        vm.refOf(state, info.source, callback)
                    end
                end)
            end
            vm.setMeta(args[1+offset], args[2+offset])
        end
    elseif name == 'require' then
        if index == 1 + offset then
            local result = vm.getLinkUris(call)
            if result then
                local myUri = guide.getRoot(call).uri
                for i = 1, #result do
                    local uri = result[i]
                    if not files.eq(uri, myUri) then
                        local ast = files.getAst(uri)
                        if ast then
                            ofCallRecv(state, ast.ast, 1, callback)
                        end
                    end
                end
            end

            local args = call.args
            if args[1+offset] then
                if args[1+offset].type == 'string' then
                    local objName = args[1+offset][1]
                    local lib = library.library[objName]
                    if lib then
                        callback(lib, 'value')
                    end
                end
            end
        end
    elseif name == 'pcall'
    or     name == 'xpcall' then
        if index >= 2-offset then
            local args = call.args
            if  args[1+offset]
            and markFlag(state, args[1+offset], STATE_USED) then
                vm.eachRef(args[1+offset], function (info)
                    local src = info.source
                    if src.type == 'function' then
                        ofCallRecv(state, src, index, callback, 1+offset)
                        ofSpecialCallRecv(state, call, src, index, callback, 1+offset)
                    end
                end)
            end
        end
    end
end

-- 自己是函数调用的接收者，引用函数定义的返回值
local function ofSelect(state, source, callback)
    local call = source.vararg
    if call.type == 'call' then
        ofCallRecv(state, call.node, source.index, callback)
        ofSpecialCallRecv(state, call, call.node, source.index, callback)
    end
end

local function ofMain(state, source, callback)
    callback(source, 'main')
end

local function getCallRecvs(call)
    local parent = call.parent
    if parent.type ~= 'select' then
        return nil
    end
    local extParent = call.extParent
    local recvs = {}
    recvs[1] = parent.parent
    if extParent then
        for i = 1, #extParent do
            local p = extParent[i]
            recvs[#recvs+1] = p.parent
        end
    end
    return recvs
end

--- 自己作为函数的参数
local function checkAsArg(state, source, callback)
    local parent = source.parent
    if not parent then
        return
    end
    if parent.type == 'callargs' then
        local call = parent.parent
        local func = call.node
        local name = func.special
        if name == 'setmetatable' then
            if parent[1] == source then
                if parent[2] then
                    vm.eachField(parent[2], function (info)
                        if info.key == 's|__index' then
                            vm.refOf(state, info.source, callback)
                        end
                    end)
                end
                local recvs = getCallRecvs(call)
                if recvs and recvs[1] then
                    vm.refOf(state, recvs[1], callback)
                end
                vm.setMeta(source, parent[2])
            end
        end
    end
end

local function ofCallSelect(state, call, index, callback)
    local slc = call.parent
    if slc.index == index then
        vm.refOf(state, slc.parent, callback)
        return
    end
    if call.extParent then
        for i = 1, #call.extParent do
            slc = call.extParent[i]
            if slc.index == index then
                vm.refOf(state, slc.parent, callback)
                return
            end
        end
    end
end

--- 自己作为函数的返回值
local function checkAsReturn(state, source, callback)
    local parent = source.parent
    if source.type == 'field'
    or source.type == 'method' then
        parent = parent.parent
    end
    if not parent or parent.type ~= 'return' then
        return
    end
    local func = guide.getParentFunction(source)
    if func.type == 'main' then
        local myUri = func.uri
        local uris = files.findLinkTo(myUri)
        if not uris then
            return
        end
        for i = 1, #uris do
            local uri = uris[i]
            local ast = files.getAst(uri)
            if ast then
                local links = vm.getLinks(ast.ast)
                if links then
                    for linkUri, calls in pairs(links) do
                        if files.eq(linkUri, myUri) then
                            for j = 1, #calls do
                                ofCallSelect(state, calls[j], 1, callback)
                            end
                        end
                    end
                end
            end
        end
    else
        local index
        for i = 1, #parent do
            if parent[i] == source then
                index = i
                break
            end
        end
        if not index then
            return
        end
        vm.eachRef(func, function (info)
            local src = info.source
            local call = src.parent
            if not call or call.type ~= 'call' then
                return
            end
            local recvs = getCallRecvs(call)
            if recvs and recvs[index] then
                vm.refOf(state, recvs[index], callback)
            elseif index == 1 then
                callback(call, 'call')
            end
        end)
    end
end

local function checkAsParen(state, source, callback)
    if source.parent and source.parent.type == 'paren' then
        vm.refOf(state, source.parent, callback)
    end
end

local function checkValue(state, source, callback)
    if source.value then
        vm.refOf(state, source.value, callback)
    end
end

local function checkSetValue(state, value, callback)
    if value.type == 'field'
    or value.type == 'method' then
        value = value.parent
    end
    local parent = value.parent
    if not parent then
        return
    end
    if parent.type == 'local'
    or parent.type == 'setglobal'
    or parent.type == 'setlocal'
    or parent.type == 'setfield'
    or parent.type == 'setmethod'
    or parent.type == 'setindex'
    or parent.type == 'tablefield'
    or parent.type == 'tableindex' then
        if parent.value == value then
            vm.refOf(state, parent, callback)
            if guide.getName(parent) == '__index' then
                if parent.type == 'tablefield'
                or parent.type == 'tableindex' then
                    local t = parent.parent
                    local args = t.parent
                    if args[2] == t then
                        local call = args.parent
                        local func = call.node
                        if func.special == 'setmetatable' then
                            vm.refOf(state, args[1], callback)
                        end
                    end
                end
            end
        end
    end
end

local function ofInParen(state, source, callback)
    vm.refOf(state, source, callback)
end

local function applyCache(cache, callback, max)
    await.delay(function ()
        return files.globalVersion
    end)
    if max then
        if max > #cache then
            max = #cache
        end
    else
        max = #cache
    end
    for i = 1, max do
        local res = callback(cache[i])
        if res ~= nil then
            return res
        end
    end
end

local function eachRef(source, result)
    local mark   = {}
    vm.refOf({}, source, function (src, mode)
        local info
        if src.mode then
            info = src
            src = info.source
        end
        if mark[src] then
            return
        end
        mark[src] = true
        if info then
            result[#result+1] = info
        elseif mode then
            result[#result+1] = {
                source = src,
                mode   = mode,
            }
        end
    end)
    return result
end

function vm.refOf(state, source, callback)
    if not markFlag(state, source, STATE_USED) then
        return
    end
    local stype = source.type
    if stype     == 'local' then
        ofLocal(state, source, callback)
    elseif stype == 'getlocal'
    or     stype == 'setlocal' then
        ofLocal(state, source.node, callback)
    elseif stype == 'setglobal'
    or     stype == 'getglobal' then
        ofGlobal(state, source, callback)
    elseif stype == 'field'
    or     stype == 'method' then
        ofField(state, source, callback)
    elseif stype == 'setfield'
    or     stype == 'getfield'
    or     stype == 'tablefield' then
        ofField(state, source.field, callback)
    elseif stype == 'setmethod'
    or     stype == 'getmethod' then
        ofField(state, source.method, callback)
    elseif stype == 'goto' then
        ofGoTo(state, source, callback)
    elseif stype == 'label' then
        ofLabel(state, source, callback)
    elseif stype == 'number'
    or     stype == 'boolean'
    or     stype == 'string' then
        ofIndex(state, source, callback)
        ofValue(state, source, callback)
    elseif stype == 'table'
    or     stype == 'function'
    or     stype == 'nil' then
        ofValue(state, source, callback)
    elseif stype == 'select' then
        ofSelect(state, source, callback)
    elseif stype == 'call' then
        ofCallRecv(state, source.node, 1, callback)
        ofSpecialCallRecv(state, source, source.node, 1, callback)
    elseif stype == 'main' then
        ofMain(state, source, callback)
    elseif stype == 'paren' then
        ofInParen(state, source.exp, callback)
    end
    checkValue(state, source, callback)
    checkSetValue(state, source, callback)
    checkAsParen(state, source, callback)
    checkAsReturn(state, source, callback)
    checkAsArg(state, source, callback)
end

--- 判断2个对象是否拥有相同的引用
function vm.isSameRef(a, b)
    local cache = vm.cache.eachRef[a]
    if cache then
        -- 相同引用的source共享同一份cache
        return cache == vm.cache.eachRef[b]
    else
        return vm.eachRef(a, function (info)
            if info.source == b then
                return true
            end
        end) or false
    end
end

--- 获取所有的引用
function vm.eachRef(source, callback, max)
    local cache = vm.cache.eachRef[source]
    if cache then
        return applyCache(cache, callback, max)
    end
    local unlock = vm.lock('eachRef', source)
    if not unlock then
        return
    end
    cache = {}
    vm.cache.eachRef[source] = cache
    eachRef(source, cache)
    unlock()
    for i = 1, #cache do
        local src = cache[i].source
        vm.cache.eachRef[src] = cache
    end
    return applyCache(cache, callback, max)
end
