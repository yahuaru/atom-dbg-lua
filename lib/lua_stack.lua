local unpack = table.unpack or unpack
local mobdebug = require "mobdebug"
local json = require "json"

function lines_from(file)
	local f = assert(io.open(file, "r"))
    local t = f:read("*all")
    f:close()
	return t
end

local function serialize(value, options) return mobdebug.line(value, options) end

function FixUTF8(s, repl)
  local p, len, invalid = 1, #s, {}
  while p <= len do
    if     s:find("^[%z\1-\127]", p) then p = p + 1
    elseif s:find("^[\194-\223][\128-\191]", p) then p = p + 2
    elseif s:find(       "^\224[\160-\191][\128-\191]", p)
        or s:find("^[\225-\236][\128-\191][\128-\191]", p)
        or s:find(       "^\237[\128-\159][\128-\191]", p)
        or s:find("^[\238-\239][\128-\191][\128-\191]", p) then p = p + 3
    elseif s:find(       "^\240[\144-\191][\128-\191][\128-\191]", p)
        or s:find("^[\241-\243][\128-\191][\128-\191][\128-\191]", p)
        or s:find(       "^\244[\128-\143][\128-\191][\128-\191]", p) then p = p + 4
    else
      if not repl then return end -- just signal invalid UTF8 string
      local repl = type(repl) == 'function' and repl(s:sub(p,p)) or repl
      s = s:sub(1, p-1)..repl..s:sub(p+1)
      table.insert(invalid, p)
      -- adjust position/length as the replacement may be longer than one char
      p = p + #repl
      len = len + #repl - 1
    end
  end
  return s, invalid
end

local function fixUTF8(...)
  local t = {...}
  -- convert to escaped decimal code as these can only appear in strings
  local function fix(s) return '\\'..string.byte(s) end
  for i = 1, #t do t[i] = FixUTF8(t[i], fix) end
  return unpack(t)
end

function getStack(response)
-- tests the functions above

	local _, _, status, res = string.find(response, "^(%d+)%s+%w+%s+(.+)%s*$")
	if status == "200" then
	  local func, err = loadstring(res)
	  if func == nil then
		    return nil, nil, err
	  end
	  local ok, stack = pcall(func)
	  if not ok then
		    return nil, nil, stack
	  end
	  return stack
	elseif status == "401" then
	  local _, _, len = string.find(response, "%s+(%d+)%s*$")
	  len = tonumber(len)
    local res = len > 0 and client:receive(len) or "Invalid stack information."
	  return nil, nil, res
	else
	  return nil, nil, "Debugger error: unexpected response after STACK"
	end
end

function dump(o)
   if type(o) == 'table' then
      local s = '{ '
      for k,v in pairs(o) do
         if type(k) ~= 'number' then k = '"'..k..'"' end
         s = s .. '['..k..'] = ' .. dump(v) .. ','
      end
      return s .. '} '
   else
      return tostring(o)
   end
end

function convert(o)
	if type(o) == 'table' then
		local s = {}
    for k,v in pairs(o) do
				s[#s+1] = {name = dump(k), value = tostring(v)}
				if type(v) == 'table' then s[#s].childs = dump(v) end
      end
      return s
   else
      return tostring(o)
   end
end

function serialize(obj, seen)
  -- Handle non-tables and previously-seen tables.
  if type(obj) ~= 'table' then return fixUTF8(serialize(obj, params)) end
  if seen and seen[obj] then return seen[obj] end

  -- New table; mark it as seen an copy recursively.
  local s = seen or {}
  local res = setmetatable({}, getmetatable(obj))
  s[obj] = res
  for k, v in pairs(obj) do res[serialize(k, s)] = serialize(v, s) end
  return res
end

local resp = io.read('*l')
local stack, _, err = getStack(resp)

local stack_result = {}

for _,frame in ipairs(stack) do
  -- check if the stack includes expected structures
  if type(frame) ~= "table" or type(frame[1]) ~= "table" or #frame[1] < 7 then break end

  -- "main chunk at line 24"
  -- "foo() at line 13 (defined at foobar.lua:11)"
  -- call = { source.name, source.source, source.linedefined,
  --   source.currentline, source.what, source.namewhat, source.short_src }
  local call = frame[1]
  -- format the function name to a readable user string
  local func_name = call[5] == "main" and "main chunk"
    or call[5] == "C" and (call[1] or "C function")
    or call[5] == "tail" and "tail call"
    or (call[1] or "anonymous function")

-- create the new tree item for this level of the call stack
--local callitem = stackCtrl:AppendItem(root, text, image.STACK)
--print("CALL ITEM: " .. text)
  local frame_info = {}
  frame_info.name = func_name
  frame_info.file = call[2]
  frame_info.line = call[3]
  frame_info.variables = {}
  -- add the local variables to the call stack item
  for name,val in pairs(type(frame[2]) == "table" and frame[2] or {}) do
	    local variable = {}
			variable['name'] = name
			variable['type'] = type(val[1])
			variable['value'] = tostring(val[1])
			variable['local'] = true
			variable['file'] = frame_info.file
			variable['expandable'] = type(val[1]) == "table"
			variable['children'] = type(val[1]) == "table" and convert(val[1]) or nil
	    frame_info.variables[#frame_info.variables + 1] = variable
  end

  -- add the upvalues for this call stack level to the tree item
  for name,val in pairs(type(frame[3]) == "table" and frame[3] or {}) do
		local variable = {}
		variable['name'] = name
		variable['type'] = type(val[1])
		variable['value'] = tostring(val[1])
		variable['local'] = true
		variable['file'] = frame_info.file
		variable['expandable'] = type(val[1]) == "table"
		variable['children'] = type(val[1]) == "table" and convert(val[1]) or nil
		frame_info.variables[#frame_info.variables + 1] = variable
  end
  stack_result[#stack_result + 1] = json.encode(frame_info)
end
t = json.encode(stack_result):gsub("\\", "")
t = t:gsub("\"{", "{")
t = t:gsub("}\"", "}")
print(t)
