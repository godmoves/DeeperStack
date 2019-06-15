--- Performs the main loop for a secure DeepStack server.
-- @script secure_deepstack_server

local arguments = require 'Settings.arguments'
local socket = require("socket")
local constants = require 'Settings.constants'

require 'ACPC.acpc_game'
require 'Player.continual_resolving'

local input_port = 0
if #arg > 0 then
  input_port = tonumber(arg[1])
else
  print("need port")
  return
end

function loop_evaluation(continual_resolving, client, last_state, last_node)

  local line, err = client:receive()
  -- if there was no error, send it back to the client
  if not err then
    print(line)
  else
    print("err:" .. err)
    -- client closed connection: accept a new one and return
    return err, continual_resolving, client, last_state, last_node
  end

  local state
  local node
  --2.1 blocks until it's our situation/turn
  state, node = acpc_game:string_to_statenode(line)

  --did a new hand start?
  if not last_state or last_state.hand_number ~= state.hand_number or node.street < last_node.street then
    continual_resolving:start_new_hand(state)
  end
  --2.2 use continual resolving to find a strategy and make an action in the current node
  local adviced_action = continual_resolving:compute_action(node, state)
  local action_id = adviced_action["action"]
  local betsize = adviced_action["raise_amount"]
  print(action_id)
  print(betsize)

  local action
  if betsize ~= nil then
    action = tostring(betsize)
  elseif action_id == constants.acpc_actions.fold then
    action = "f"
  elseif action_id == constants.acpc_actions.ccall then
    action = "c"
  else
    action = "WTF"
  end
  last_state = state
  last_node = node
  collectgarbage()

  return action, continual_resolving, client, last_state, last_node
end

--1.0 create the ACPC game and connect to the server
acpc_game = ACPCGame()

continual_resolving = ContinualResolving()

last_state = nil
last_node = nil

-- load namespace
-- create a TCP socket and bind it to the local host, at any port
server = assert(socket.bind("*", input_port))
ip, port = server:getsockname()
print(ip .. ": " .. port)

client = server:accept()
print("accepted client")

while 1 do
  local v, msg, continual_resolving_l, client_l, last_state_l, last_node_l = pcall(loop_evaluation, continual_resolving, client, last_state, last_node)

  print(v, msg)

  if v then
    continual_resolving = continual_resolving_l
    client = client_l
    last_state = last_state_l
    last_node = last_node_l

    if msg == "closed" then
      print("client closed, waiting for new one")
      client = server:accept()
      print("accepted client")
    else
      client:send(msg .. "\n")
    end

  else
    client:send("ERR" .. "\n")
  end
end
