local core = require "sproto.core"
local assert = assert

local sproto = {}
local host = {}

local weak_mt = { __mode = "kv" }
local sproto_mt = { __index = sproto }
local sproto_nogc = { __index = sproto }
local host_mt = { __index = host }

-- sproto 对象的 gc 处理
function sproto_mt:__gc()
	core.deleteproto(self.__cobj)
end

-- 根据二进制字符串生成 sproto 对象
-- @param bin 二进制字符串, 通过 sprotoparser.parse 生成
-- @return sproto 对象
function sproto.new(bin)
	local cobj = assert(core.newproto(bin))
	local self = {
		__cobj = cobj,	-- struct sproto
		__tcache = setmetatable( {} , weak_mt ),	-- 缓存 querytype 的查询结果
		__pcache = setmetatable( {} , weak_mt ),	-- 缓存 queryproto 的查询结果
	}
	return setmetatable(self, sproto_mt)
end

-- 通过 core.newproto 生成的对象生成 sproto 对象 
-- @param cobj 由 core.newproto 对象生成的对象
-- @return sproto 对象
function sproto.sharenew(cobj)
	local self = {
		__cobj = cobj,	-- struct sproto
		__tcache = setmetatable( {} , weak_mt ),	-- 缓存 querytype 的查询结果
		__pcache = setmetatable( {} , weak_mt ),	-- 缓存 queryproto 的查询结果
	}
	return setmetatable(self, sproto_nogc)	-- 注意, 这里使用的是 nogc 的原表
end

-- 解析模式字符串, 生成 1 个 sproto 对象.
-- @param ptext 模式字符串
-- @return sproto 对象
function sproto.parse(ptext)
	local parser = require "sprotoparser"
	local pbin = parser.parse(ptext)
	return sproto.new(pbin)
end

-- 这条调用会返回一个 host 对象，用于处理接收的消息。
-- @param packagename packagename 默认值为 "package" 即对应 .package 类型。你也可以起别的名字。
-- @return host 对象
function sproto:host(packagename)
	packagename = packagename or "package"
	local obj = {
		__proto = self,	-- lua sproto 对象
		__package = core.querytype(self.__cobj, packagename),	-- struct sproto_type, RPC 协议包的主体格式
		__session = {},
	}
	return setmetatable(obj, host_mt)
end

-- 查询得到 struct sproto_type 对象
-- @param self sproto 对象
-- @param typename 定义的类型名字
-- @return struct sproto_type 对象
local function querytype(self, typename)
	local v = self.__tcache[typename]

	-- 查询 struct sproto_type 对象, 并且缓存起来
	if not v then
		v = core.querytype(self.__cobj, typename)
		self.__tcache[typename] = v
	end

	return v
end

-- 判断一个类型是否存在
-- @param typename 类型的名字
-- @return true 存在, 否则不存在
function sproto:exist_type(typename)
	local v = self.__tcache[typename]
	if not v then
		return core.querytype(self.__cobj, typename) ~= nil
	else
		return true
	end
end

-- encodes a lua table by a type object, and generates a string message.
-- 将 1 个 table 通过类型对象编码, 然后返回 1 个字符串消息.
-- @param typename 类型名字
-- @param tbl lua table 对象
-- @return 字符串消息
function sproto:encode(typename, tbl)
	local st = querytype(self, typename)
	return core.encode(st, tbl)
end

-- decodes a message string generated by sproto.encode with type.
-- 将 sproto.encode 编码后的字符串解码出来.
-- @param typename 类型名字
-- @param ... 如果是 1 个参数, 那么需要是 string 类型; 如果是 2 个参数, 那么需要是 userdata/lightuserdata 和表示数据的长度
-- @return table 对象(之前被 sproto.encode 编码)
function sproto:decode(typename, ...)
	local st = querytype(self, typename)
	return core.decode(st, ...)
end

-- 将 sproto.encode 返回的字符串使用 0-pack 算法压缩
-- @param typename 类型名字
-- @param tbl lua table 对象
-- @return 0-pack 压缩后的字符串消息
function sproto:pencode(typename, tbl)
	local st = querytype(self, typename)
	return core.pack(core.encode(st, tbl))
end

-- 将数据解压之后再解码返回 table 对象
-- @param typename 类型名字
-- @param ... 如果是 1 个参数, 那么需要是 string 类型; 如果是 2 个参数, 那么需要是 userdata/lightuserdata 和表示数据的长度
-- @return table 对象(之前被 sproto.pencode 编码)
function sproto:pdecode(typename, ...)
	local st = querytype(self, typename)
	return core.decode(st, core.unpack(...))
end

-- 查询 sproto 对象的协议, 用于 RPC
-- @param self sproto 对象
-- @param pname 字段的名字(字符串类型)或者字段的标记(整型)
-- @return table 类型
local function queryproto(self, pname)
	local v = self.__pcache[pname]

	-- 查询协议, 同时缓存起来
	if not v then
		local tag, req, resp = core.protocol(self.__cobj, pname)
		assert(tag, pname .. " not found")
		if tonumber(pname) then
			pname, tag = tag, pname
		end
		v = {
			request = req,		-- struct sproto_type
			response = resp,	-- struct sproto_type
			name = pname,		-- 协议字段名
			tag = tag,			-- 协议标记
		}
		self.__pcache[pname] = v
		self.__pcache[tag] = v
	end

	return v
end

-- 判断一个协议是否存在
-- @param pname 协议名字
-- @return true 存在, false 不存在
function sproto:exist_proto(pname)
	local v = self.__pcache[pname]
	if not v then
		return core.protocol(self.__cobj, pname) ~= nil
	else
		return true
	end
end

-- 将协议请求编码
-- @param protoname 协议的名字
-- @param tbl table 对象, 请求的数据内容
-- @return 编码后的字符串对象和此协议的标记(tag)
function sproto:request_encode(protoname, tbl)
	local p = queryproto(self, protoname)
	local request = p.request
	if request then
		return core.encode(request, tbl), p.tag
	else
		return "", p.tag
	end
end

-- 将协议响应编码
-- @param protoname 协议的名字
-- @param tbl table 对象, 响应的数据内容
-- @return 编码后的字符串对象
function sproto:response_encode(protoname, tbl)
	local p = queryproto(self, protoname)
	local response = p.response
	if response then
		return core.encode(response, tbl)
	else
		return ""
	end
end

-- 将协议请求解码
-- @param protoname 协议的名字
-- @param ... 如果是 1 个参数, 那么需要是 string 类型; 如果是 2 个参数, 那么需要是 userdata/lightuserdata 和表示数据的长度
-- @return 解码后的 table 对象和协议的名字
function sproto:request_decode(protoname, ...)
	local p = queryproto(self, protoname)
	local request = p.request
	if request then
		return core.decode(request, ...), p.name
	else
		return nil, p.name
	end
end

-- 将协议的响应解码
-- @param protoname 协议的名字
-- @param ... 如果是 1 个参数, 那么需要是 string 类型; 如果是 2 个参数, 那么需要是 userdata/lightuserdata 和表示数据的长度
-- @return 解码后的 table 对象
function sproto:response_decode(protoname, ...)
	local p = queryproto(self, protoname)
	local response = p.response
	if response then
		return core.decode(response, ...)
	end
end

sproto.pack = core.pack
sproto.unpack = core.unpack

-- 获得默认表对象
-- @param typename 类型名字
-- @param type 如果有值, 必须是 "REQUEST" 或者 "RESPONSE" 之一, 主要是针对 RPC 消息的处理.
-- @return table 对象
function sproto:default(typename, type)
	if type == nil then
		return core.default(querytype(self, typename))
	else
		local p = queryproto(self, typename)
		if type == "REQUEST" then
			if p.request then
				return core.default(p.request)
			end
		elseif type == "RESPONSE" then
			if p.response then
				return core.default(p.response)
			end
		else
			error "Invalid type"
		end
	end
end

local header_tmp = {}

local function gen_response(self, response, session)
	return function(args)
		header_tmp.type = nil
		header_tmp.session = session
		local header = core.encode(self.__package, header_tmp)
		if response then
			local content = core.encode(response, args)
			return core.pack(header .. content)
		else
			return core.pack(header)
		end
	end
end

-- 用于处理一条消息。
-- @param ... 可以是 1 个字符串, 或者是 1 个 userdata 和所指向数据的长度. 它应符合上述的以 sproto 的 0-pack 方式打包的包格式。
-- @return 两种可能的返回类别，由第一个返回值决定：

-- REQUEST : 第一个返回值为 "REQUEST" 时，表示这是一个远程请求。如果请求包中没有 session 字段，表示该请求不需要回应。
-- 这时，第 2 和第 3 个返回值分别为消息类型名（即在 sproto 定义中提到的某个以 . 开头的类型名），以及消息内容（通常是一个 table ）；
-- 如果请求包中有 session 字段，那么还会有第 4 个返回值：一个用于生成回应包的函数。

-- RESPONSE ：第一个返回值为 "RESPONSE" 时，第 2 和 第 3 个返回值分别为 session 和消息内容。
-- 消息内容通常是一个 table ，但也可能不存在内容（仅仅是一个回应确认）。
function host:dispatch(...)
	local bin = core.unpack(...)
	header_tmp.type = nil
	header_tmp.session = nil
	local header, size = core.decode(self.__package, bin, header_tmp)
	local content = bin:sub(size + 1)
	if header.type then
		-- request
		local proto = queryproto(self.__proto, header.type)
		local result
		if proto.request then
			result = core.decode(proto.request, content)
		end
		if header_tmp.session then
			return "REQUEST", proto.name, result, gen_response(self, proto.response, header_tmp.session)
		else
			return "REQUEST", proto.name, result
		end
	else
		-- response
		local session = assert(header_tmp.session, "session not found")
		local response = assert(self.__session[session], "Unknown session")
		self.__session[session] = nil
		if response == true then
			return "RESPONSE", session
		else
			local result = core.decode(response, content)
			return "RESPONSE", session, result
		end
	end
end

-- attach 可以构造一个发送函数，用来将对外请求打包编码成可以被 dispatch 正确解码的数据包。
-- @param sp sproto 对象, 指向外发出的消息协议定义。
-- @return 函数对象, 该函数的功能如下所描述
function host:attach(sp)
	-- 这个 sender 函数接受三个参数（name, args, session）。
	-- @param name 是协议的字符串名
	-- @param args 是一张保存用消息内容的 table, 即: 发送请求的数据
	-- @param session 是你提供的唯一识别号，用于让对方正确的回应。 当你的协议不规定不需要回应时，session 可以不给出。同样，args 也可以为空。
	-- @return 对外请求打包数据
	return function(name, args, session)
		local proto = queryproto(sp, name)
		header_tmp.type = proto.tag
		header_tmp.session = session
		local header = core.encode(self.__package, header_tmp)

		if session then
			self.__session[session] = proto.response or true
		end

		if args then
			local content = core.encode(proto.request, args)
			return core.pack(header .. content)
		else
			return core.pack(header)
		end
	end
end

return sproto
