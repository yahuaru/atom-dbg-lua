local unpack = table.unpack or unpack
local mobdebug = require "mobdebug"

local resp = io.read('*l')

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
  		print("Error in stack information: " .. err)
  		return nil, nil, err
	  end
	  local ok, stack = pcall(func)
	  if not ok then
  		print("Error in stack information: " .. stack)

  		return nil, nil, stack
	  end
	  for _,frame in ipairs(stack) do
  		print(mobdebug.line(frame[1], {comment = false}))
	  end
	  return stack
	elseif status == "401" then
	  local _, _, len = string.find(response, "%s+(%d+)%s*$")
	  len = tonumber(len)
	  local res = len > 0 and client:receive(len) or "Invalid stack information."
	  print("Error in expression: " .. res)
	  return nil, nil, res
	else
	  print("Unknown error")
	  return nil, nil, "Debugger error: unexpected response after STACK"
	end
end

local stack, _, err = getStack(resp)

for _,frame in ipairs(stack) do
  -- check if the stack includes expected structures
  if type(frame) ~= "table" or type(frame[1]) ~= "table" or #frame[1] < 7 then break end

  -- "main chunk at line 24"
  -- "foo() at line 13 (defined at foobar.lua:11)"
  -- call = { source.name, source.source, source.linedefined,
  --   source.currentline, source.what, source.namewhat, source.short_src }
  local call = frame[1]

  -- format the function name to a readable user string
  local func = call[5] == "main" and "main chunk"
    or call[5] == "C" and (call[1] or "C function")
    or call[5] == "tail" and "tail call"
    or (call[1] or "anonymous function")

  -- format the function treeitem text string, including the function name
  local text = func ..
    (call[4] == -1 and '' or " at line "..call[4]) ..
    (call[5] ~= "main" and call[5] ~= "Lua" and ''
     or (call[3] > 0 and " (defined at "..call[7]..":"..call[3]..")"
                      or " (defined in "..call[7]..")"))

  -- create the new tree item for this level of the call stack
  --local callitem = stackCtrl:AppendItem(root, text, image.STACK)
    print("CALL ITEM: " .. text)
  -- register call data to provide stack navigation
  --callData[callitem:GetValue()] = { call[2], call[4] }

  -- add the local variables to the call stack item
  for name,val in pairs(type(frame[2]) == "table" and frame[2] or {}) do
    -- format the variable name, value as a single line and,
    -- if not a simple type, the string value.
    local value = val[1]
    local text = ("%s = %s"):format(name, fixUTF8(serialize(value, params)))
    print("VALUE: " .. text)
    --local item = stackCtrl:AppendItem(callitem, text, image.LOCAL)
    --stackCtrl:SetItemValueIfExpandable(item, value, forceexpand)
    --stackCtrl:SetItemName(item, name)
  end

  -- add the upvalues for this call stack level to the tree item
  for name,val in pairs(type(frame[3]) == "table" and frame[3] or {}) do
    local value = val[1]
    local text = ("%s = %s"):format(name, fixUTF8(serialize(value, params)))
    print("VALUE: " .. text)
    --local item = stackCtrl:AppendItem(callitem, text, image.UPVALUE)
    --stackCtrl:SetItemValueIfExpandable(item, value, forceexpand)
    --stackCtrl:SetItemName(item, name)
  end
end
io.flush()
