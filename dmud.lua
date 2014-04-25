print("Lua file loaded!")
function DMUD_ReceivedBytes(client,bytes)
 print("The client said:\n"..bytes)
end
function DMUD_ClientDisconnected(client)
 print("Client disconnected! "..client)
end
function DMUD_ClientConnected(client)
 print("Client Connected! "..client)
 sendToClient(client,"HTTP/1.0 200 OK\nContent-Type: text/html; charset=utf-8\n\nHello World!\n")
 --disconnectClient(client);
end