--- Performs the main loop for manual input player.
-- @script manual_input_player

local socket = require('socket')
local arguments = require 'Settings.arguments'


local port = 0
if #arg > 0 then
  port = tonumber(arg[1])
else
  print("need port")
  return
end

connection = assert(socket.connect(arguments.acpc_server, port))

while true do

  print("send message")
  local msg = io.read()

  connection:send(msg .. '\r\n') 

  local out, status = connection:receive('*l')

  print("msg received")
  print(out, status)


  collectgarbage()
end
