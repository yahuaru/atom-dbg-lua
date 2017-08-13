local copas = require "copas"
local mobdebug = require "mobdebug"
local socket = require "socket"
local server = socket.bind('*', 8172)

print("Lua Remote Debugger")
print("Run the program you wish to debug")

io.flush()

local client = server:accept()

print("*connected");

io.flush()

local running = false
copas.addthread(function() mobdebug.handle(command, client) end)
local command = ""
command = io.read("*l")

while command ~= "exit" do

	if command == "run" then
		handle_async(command, client)
		print("^running")
		io.flush()
		running = true
	else
		local result, line, err = mobdebug.handle(command, client)
		print(table.concat({"^done", result, line, err}, " "))
		io.flush()
	end

	command = io.read("*l")
end
