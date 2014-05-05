states = states or {}
names = names or {}
print("Lua file loaded!")
function DMUD_ReceivedLine(client,line)
 local state = states[client]
 print("Client said: "..line.." (state:"..state..")\r\n")
 
 if state == "login" then
  --Determine if the player exists
  local moo = keyval_get("player-"..line)
  print("\r\n***"..keyval_get("player-"..line).."\r\n")
  print(string.format("\r\nLength: %d",moo:len()))
  
  
  
  if keyval_get("player-"..line):len() > 0 then
   states[client] = 'password'
   sendToClient(client,"Password?\r\n")
  else
   names[client] = line
   states[client] = 'confirmName'
   sendToClient(client,"Are you sure you want "..line.." to be your name? (Y/N)\r\n")
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
  keyval_put("player_"..names[client].."_password",sha1(line))
  sendToClient(client,"Please confirm your password:\r\n")
  states[client] = 'confirmPassword'
 elseif state == "confirmPassword" then
  if sha1(line) == keyval_get("player_"..names[client].."_password") then
   --Create an account
   keyval_put("player_"..names[client],1)
   keyval_put("player_"..names[client].."_level",1)
   states[client] = 'play'
   sendToClient(client,"Welcome! Your account has been created.\r\n")
  else
   states[client] = 'createPassword'
   sendToClient(client,"I'm sorry, your passwords did not match. Please try again.")
  end
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
 --sendToClient(client,"HTTP/1.0 200 OK\nContent-Type: text/html; charset=utf-8\n\nHello World!\n")
 --disconnectClient(client);
end
function DMUD_Heartbeat(client)
 --sendToClient(client,"Hey how's it going!?")
end