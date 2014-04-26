import std.stdio;
import std.socket;
import std.algorithm;
import std.file;
import std.datetime;
import std.format;
import std.zlib;
import core.thread;
import luad.all;
Client[int] clients;
const Duration instant = dur!"hnsecs"(0);
immutable char IAC = 255;
immutable char SB = 250; //Subnegotiation begin
immutable char SE = 240; //Subnegotiation end
immutable char WILL = 251;
immutable char DO = 253;
immutable char MCCP = 86;

class Client {
    Socket socket;
    bool mccp = false;
    Compress mccpCompressor;
    char[] toSend = "".dup;
    this (Socket sock) {
        this.socket = sock;
    }
    bool send (char[] message) {        
        if (this.mccp) { //compress if we're in mccp mode // 
            message = cast(char[])this.mccpCompressor.compress(cast(void[])message) ~ cast(char[])this.mccpCompressor.flush(Z_FULL_FLUSH);
        }
        SocketSet checkWrite = new SocketSet();
        checkWrite.add(this.socket);
        if (Socket.select(null,checkWrite,null,instant) > 0) {
            this.socket.send(message);
        } else {
            this.toSend ~= message;
        }
        return true;
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
	SocketSet checkRead = new SocketSet();
	SocketSet checkWrite = new SocketSet();
    
    LuaFunction DMUD_ReceivedBytes;
    LuaFunction DMUD_ClientConnected;
    LuaFunction DMUD_ClientDisconnected;
    LuaFunction DMUD_Heartbeat;
    int clientCount = 0; //Internal client count, used to make a unique string for each client key
    while(true) {   	
    	if (lastModifiedTimeLua < timeLastModified("dmud.lua").toUnixTime()) {
    		writefln("Reloading Lua file");
    		lua.doFile("dmud.lua");
    		//Go through each of our special functions and make it a noop in case it's not defined
    		lua.doString(q"EOS
            local noop = function () return true end
            local keys = {'DMUD_ReceivedBytes','DMUD_ClientConnected','DMUD_ClientDisconnected','DMUD_Heartbeat'}
            for _,key in ipairs(keys) do
                if _G[key] == nil then _G[key] = noop end
            end
EOS");
    		DMUD_ReceivedBytes = lua.get!LuaFunction("DMUD_ReceivedBytes");
    		DMUD_ClientDisconnected = lua.get!LuaFunction("DMUD_ClientDisconnected");
    		DMUD_ClientConnected = lua.get!LuaFunction("DMUD_ClientConnected");
    		DMUD_Heartbeat = lua.get!LuaFunction("DMUD_Heartbeat");
    		lastModifiedTimeLua = timeLastModified("dmud.lua").toUnixTime();
    		lua["sendToClient"] = (int client, char[] message) {
		        if (client in clients) {
		            clients[client].send(message);
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
    	    client.blocking(false);
    	    clientCount++;
    	    clients[clientCount] = new Client(client);
    	    DMUD_ClientConnected(clientCount);
    	    clients[clientCount].send([IAC,WILL,MCCP]);
	    }
	    foreach (int key, Client c; clients) {
	        checkRead.reset();
	        checkRead.add(c.socket);
	        if (Socket.select(checkRead,null,null,instant) > 0) {
	            char[1024] buffer;
	            auto received = c.socket.receive(buffer);
	            if (received < 0) { //They closed the connection, less than 0 can also mean they closed the connection
	                //clients = remove(clients,i);
	                DMUD_ClientDisconnected(key);
	                clients.remove(key);
	                break;
                } else {
                    printf("%d bytes received",received);
                    
                    for (int i = 0;i < received;i++) {
                        char current_char = buffer[i]; 
                        printf("%d,",current_char);
                        if (current_char == IAC) { //command incoming!
                            if (received - i > 0) { //We have more buffer to read
                                if (buffer[i+1] == DO && received - i > 1) { //We have a DO and another byte to read
                                    if (buffer[i+2] == MCCP) { // IAC DO MCCP
                                        //Confirm with subnegot. per http://tintin.sourceforge.net/mccp/ 
                                        clients[key].send([IAC,SB,MCCP,IAC,SE]);
                                        clients[key].mccpCompressor = new Compress;
                                        clients[key].mccp = true;
                                    }
                                }
                                
                            }
                        }
                    }
                    DMUD_ReceivedBytes(key,buffer);
                }
            }
	        
	        if (c.toSend.length > 0) {
                 checkWrite.reset();
                 checkWrite.add(c.socket);
                 if (Socket.select(null,checkWrite,null,instant) > 0) {
                     c.socket.send(c.toSend);
                     c.toSend = "".dup;
                 } 
	        }
	        DMUD_Heartbeat(key); //Call the heartbeat function for each client, each tick.
        }
	    Thread.sleep( dur!("msecs")( 20 ) ); //Sleep to slow the CPU eating behavior of the busy wait
    }
}
