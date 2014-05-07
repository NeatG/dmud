states = states or {}
names = names or {}
print("Lua file loaded!")
function DMUD_ReceivedLine(client,line)
 local state = states[client]
 print("Client said: "..line.." (state:"..state..")\r\n")
 print("Length: "..line:len())
 
 if state == "login" then
  --Determine if the player exists
  local moo = keyval_get("player_"..line)

  
  
  
  if keyval_get("player_"..line):len() > 0 then
   states[client] = 'password'
   names[client] = line
   sendToClient(client,"Password?\r\n")
  else
   names[client] = line
   states[client] = 'confirmName'
   sendToClient(client,"Are you sure you want "..line.." to be your name? (Y/N)\r\n\r\n")
  end
 elseif state == "confirmName" then
  line = line:lower()
  if line == "y" or line == "yes" then
   sendToClient(client,"A fine name indeed. What password would you like?")
   states[client] = "createPassword"
  elseif line == "n" or line == "no" then
   sendToClient(client,"What is your name, then?")
   states[client] = 'login'
  else
   sendToClient(client,"Are you sure you want "..names[client].." to be your name? (Y/N)\r\n")
  end
 elseif state == "createPassword" then
  keyval_put("player_"..names[client].."_password",sha1_raw(line))
  sendToClient(client,"Please confirm your password:\r\n")
  states[client] = 'confirmPassword'
 elseif state == "confirmPassword" then
  if sha1_raw(line) == keyval_get("player_"..names[client].."_password") then
   --Create an account
   keyval_put("player_"..names[client],"1")
   keyval_put("player_"..names[client].."_level","1")
   states[client] = 'play'
   sendToClient(client,"Welcome! Your account has been created.\r\n")
  else
   states[client] = 'createPassword'
   sendToClient(client,"I'm sorry, your passwords did not match. Please try again.")
  end
 elseif state == "password" then
  if (sha1_raw(line) == keyval_get("player_"..names[client].."_password")) then
   states[client] = "play"
   sendToClient(client,"Welcome back!")
  else 
   sendToClient(client,"Password incorrect.")
   disconnectClient(client)
  end
 elseif state == "play" then
  sendToClient(client,sha1_raw(line)..sha1_raw(line):len().."\r\n");
 end
end
function DMUD_ClientDisconnected(client)
 print("Client disconnected! "..client)
 states[client] = nil
end
function DMUD_ClientConnected(client)
 print("Client Connected! "..client)
 states[client] = 'login'
 sendToClient(client,'What is your name?\r\n');
 --disconnectClient(client);
end
function DMUD_Heartbeat(client)

 --sendToClient(client,"Hey how's it going!?")
end