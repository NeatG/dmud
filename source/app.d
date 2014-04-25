import std.stdio;
import std.socket;
import std.algorithm;
import std.file;
import std.datetime;
import luad.all;
Client[int] clients;
class Client {
    Socket socket;
    char[] toSend = "".dup;
    this (Socket sock) {
        this.socket = sock;
    }
}
void main() {
    auto lua = new LuaState; //Create the Lua state and initialize the libraries
    lua.openLibs();
    int lastModifiedTimeLua = 0; //MTime for the Lua file
    Socket server = new TcpSocket(); //Make a server socket listening on port 8080
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.blocking(false);
    server.bind(new InternetAddress(8080));
    server.listen(1);
    Duration instant = dur!"hnsecs"(0);
	SocketSet checkRead = new SocketSet();
	SocketSet checkWrite = new SocketSet();
    
    LuaFunction DMUD_ReceivedBytes;
    LuaFunction DMUD_ClientConnected;
    LuaFunction DMUD_ClientDisconnected;
    int clientCount = 0; //Internal client count, used to make a unique string for each client key
    while(true) {   	
    	if (lastModifiedTimeLua < timeLastModified("dmud.lua").toUnixTime()) {
    		writefln("Reloading Lua file");
    		lua.doFile("dmud.lua");
    		//Go through each of our special functions and make it a noop in case it's not defined
    		lua.doString(q"EOS
            local noop = function () return true end
            local keys = {'DMUD_ReceivedBytes','DMUD_ClientConnected','DMUD_ClientDisconnected'}
            for _,key in ipairs(keys) do
                if _G[key] == nil then _G[key] = noop end
            end
EOS");
    		DMUD_ReceivedBytes = lua.get!LuaFunction("DMUD_ReceivedBytes");
    		DMUD_ClientDisconnected = lua.get!LuaFunction("DMUD_ClientDisconnected");
    		DMUD_ClientConnected = lua.get!LuaFunction("DMUD_ClientConnected");
    		lastModifiedTimeLua = timeLastModified("dmud.lua").toUnixTime();
    		lua["sendToClient"] = (int client, char[] message) {
		        if (client in clients) {
		            clients[client].toSend ~= message;
		            return 1;
	            }
	            return 0;
    		};
            lua["disconnectClient"] = (int client) {
                if (client in clients) {
                    clients[client].socket.shutdown(SocketShutdown.BOTH);
                    clients[client].socket.close();
                    clients.remove(client);
                    return 1;
                }
                return 0;
            };
    	}
    	checkRead.reset(); //Reset checkRead and add server socket
    	checkRead.add(server);
    	if (Socket.select(checkRead,null,null,instant) > 0) {
    	    Socket client = server.accept();
    	    clientCount++;
    	    clients[clientCount] = new Client(client);
    	    DMUD_ClientConnected(clientCount);
	    }
	    foreach (int key, Client c; clients) {
	        checkRead.reset();
	        checkRead.add(c.socket);
	        if (Socket.select(checkRead,null,null,instant) > 0) {
	            char[1024] buffer;
	            auto received = c.socket.receive(buffer);
	            if (received == 0) { //They closed the connection
	                //clients = remove(clients,i);
	                DMUD_ClientDisconnected(key);
	                clients.remove(key);
	                break;
                } else {
                    DMUD_ReceivedBytes(key,buffer);
                }
            }
	        
	        if (c.toSend.length > 0) {
                 checkWrite.reset();
                 checkWrite.add(c.socket);
                 writefln("Checking things!");
                 if (Socket.select(null,checkWrite,null,instant) > 0) {
                     c.socket.send(c.toSend);
                     c.toSend = "".dup;
                 }
                 
	        }
        }
    }
}
