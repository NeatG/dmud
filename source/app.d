import std.stdio;
import std.socket;
import std.algorithm;
import std.file;
import std.datetime;
import std.format;
import std.zlib;
import std.digest.sha;
import core.thread;
import luad.all;
import d2sqlite3;
import std.base64;
Client[int] clients;
const Duration instant = dur!"hnsecs"(0);
//Telnet OPTS
immutable char IAC = 255;
immutable char GA = 249;
immutable char CR = 13;
immutable char LF = 10;
immutable char SB = 250; //Subnegotiation begin
immutable char SE = 240; //Subnegotiation end
immutable char WILL = 251;
immutable char DO = 253;
immutable char DONT = 254;
immutable char MCCP = 86;
immutable char MXP = 91;
immutable char GMCP = 201;

string[string] keyValue; //Local cache of the key/value store
int[] clientsToDelete; //Array of clients to be deleted.

class Client {
    Socket socket;
    bool mccp = false;
    bool mxp = false;
    bool gmcp = false;
    Compress mccpCompressor;
    char[] toSend = "".dup;
    char[] toRecv = "".dup;
    this (Socket sock) {
        this.socket = sock;
    }
    bool send (char[] message) {        
        if (this.mccp) { //compress if we're in mccp mode // 
            message = cast(char[])this.mccpCompressor.compress(cast(void[])message.dup);
            message ~= cast(char[])this.mccpCompressor.flush(Z_SYNC_FLUSH );
        }
        SocketSet checkWrite = new SocketSet();
        checkWrite.add(this.socket);
        if (Socket.select(null,checkWrite,null,instant) > 0) {
            this.socket.send(message);
        } else {
            writeln("We couldn't send the message just yet!");
            this.toSend ~= message;
        }
        return true;
    }
}
char[] sha1b64 (char[] input) { //Returns a base64 encoded SHA1
    auto ctx = makeDigest!SHA1();
    ctx.put(cast(ubyte[])input);
    ubyte[] hash = ctx.finish();
    char[] encoded = Base64.encode(hash);
    return encoded;
}
void main() {
    auto lua = new LuaState; //Create the Lua state and initialize the libraries
    lua.openLibs();
    int lastModifiedTimeLua = 0; //MTime for the Lua file
    Database db;
    try
    {
        db = Database("dmud.db");
    }
    catch (SqliteException e)
    {
        // Error creating the database
        assert(false, "Error: " ~ e.msg);
    }
    try //Create our key/value store.
    {
        db.execute(
            "CREATE TABLE IF NOT EXISTS key_value (
                key TEXT NOT NULL PRIMARY KEY,
                value TEXT
             )"
        );
    }
    catch (SqliteException e)
    {
        // Error creating the table.
        assert(false, "Error: " ~ e.msg);
    }
    Socket server = new TcpSocket(); //Make a server socket listening on port 8080
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.blocking(false);
    server.bind(new InternetAddress(8080));
    server.listen(1);
	SocketSet checkRead = new SocketSet();
	SocketSet checkWrite = new SocketSet();
    
    LuaFunction DMUD_ReceivedBytes;
    LuaFunction DMUD_ReceivedLine;
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
            local keys = {'DMUD_ReceivedBytes','DMUD_ReceivedLine','DMUD_ClientConnected','DMUD_ClientDisconnected','DMUD_Heartbeat'}
            for _,key in ipairs(keys) do
                if _G[key] == nil then _G[key] = noop end
            end
EOS");
    		DMUD_ReceivedBytes = lua.get!LuaFunction("DMUD_ReceivedBytes");
    		DMUD_ReceivedLine = lua.get!LuaFunction("DMUD_ReceivedLine");
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
                    clientsToDelete ~= client;
                    return 1;
                }
                return 0;
            };
            lua["keyval_put"] = (char[] key, char[] value) { //Put something in the key value store
                try { //Create our key/value store.
                     auto query = db.query("INSERT OR REPLACE INTO key_value (key, value) VALUES (:key, :value)");
                     query.params.bind(":key",key).bind(":value",value);
                     query.execute();                     
                }
                catch (SqliteException e) {
                    assert(false, "Error: " ~ e.msg);
                }
                immutable(char)[] newValue = value.dup;
                immutable(char)[] newKey = key.dup;
                keyValue[newKey] = newValue;
            };
            lua["keyval_get"] = (char[] key) { //Put something in the key value store
                const(immutable(char))[] newKey = key.dup;
                writeln("Requested: "~newKey);
                if (!(newKey in keyValue)) {
                    writeln("Not found in cache, going to SQLite");
                    try {
                        auto query = db.query("SELECT value FROM key_value WHERE key == \""~newKey~"\"");
                        
                        foreach (row; query.rows) {
                            
                            keyValue[newKey] = row["value"].get!string();
                            writeln("Value: "~keyValue[newKey]);
                            return keyValue[newKey];
                        }
                    }
                    catch (SqliteException e) {
                        assert(false, "Error: " ~ e.msg);
                    }
                } else {
                    writeln("Found and returning!");
                    return keyValue[newKey];
                }
                
                return null;
            };         
            lua["sha1_raw"] = &sha1b64;  
    	}
    	checkRead.reset(); //Reset checkRead and add server socket
    	checkRead.add(server);
    	if (Socket.select(checkRead,null,null,instant) > 0) {
    	    Socket client = server.accept();
    	    //client.blocking(false);
    	    clientCount++;
    	    clients[clientCount] = new Client(client);
    	    DMUD_ClientConnected(clientCount);
    	    clients[clientCount].send([IAC,WILL,MCCP]);
    	    clients[clientCount].send([IAC,WILL,MXP]);
    	    clients[clientCount].send([IAC,WILL,GMCP]);
	    }
    	if (clientsToDelete.length > 0) {
    	    foreach (int client; clientsToDelete) {
        	    clients[client].socket.shutdown(SocketShutdown.BOTH);
                clients[client].socket.close();
                DMUD_ClientDisconnected(client);
                clients.remove(client);
        	}
    	    clientsToDelete = clientsToDelete.init;
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
                    c.toRecv ~= buffer[0..received];
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
	        if (c.toRecv.length > 0) {
	            char[] temp_buffer;
	            bool iac_mode = false;
	            bool do_mode = false;
	            bool dont_mode = false;
	            printf("Client buffer length: %d\r\n",c.toRecv.length);
	            for (int i = 0;i < c.toRecv.length;i++) {
	                char current_char = c.toRecv[i]; 
                    printf("%d,",current_char);
                    if (current_char == IAC) { iac_mode = true; }
                    if (iac_mode && current_char == DO) { do_mode = true; } 
                    if (iac_mode && current_char == DONT) { dont_mode = true; }
                    if (iac_mode && do_mode && current_char != DO) { //IAC DO
                        if (current_char == MCCP) { //IAC DO MCCP
                            //Confirm with subnegot. per http://tintin.sourceforge.net/mccp/ 
                            c.send([IAC,SB,MCCP,IAC,SE]);
                            c.mccpCompressor = new Compress;
                            c.mccp = true;                                
                        }
                        else if (current_char == MXP) {
                            c.send([IAC,SB,MXP,IAC,SE]);
                            c.mxp = true;                                
                        }
                        else if (current_char == GMCP) {
                            c.send([IAC,SB,GMCP,IAC,SE]);
                            c.gmcp = true;
                        }
                        //We either dealt with it or don't support it
                        iac_mode = false;
                        do_mode = false;
                        c.toRecv = c.toRecv[i+1..$];
                        break;
                    }
                    if (iac_mode && dont_mode && current_char != DONT) { //IAC DON'T
                        if (current_char == MCCP) { c.mccp = false; }
                        if (current_char == MXP) { c.mxp = false; }
                        if (current_char == GMCP) { c.gmcp = false; }
                        iac_mode = false;
                        dont_mode = false;
                        c.toRecv = c.toRecv[i+1..$];
                        break;                        
                    }
                    if (!iac_mode && current_char < 127 && current_char != CR && current_char != LF) { temp_buffer ~= current_char; } //Only add basic ASCII to this buffer
                    if (current_char == LF) {
                        if (temp_buffer.length > 0) { DMUD_ReceivedLine(key,temp_buffer); }
                        //Clear our toRecv buffer up to i
                        c.toRecv = c.toRecv[i+1..$];
                        break;
                    } 
                    
	            }
	        }
	        DMUD_Heartbeat(key); //Call the heartbeat function for each client, each tick.
        }
	    Thread.sleep( dur!("msecs")( 20 ) ); //Sleep to slow the CPU eating behavior of the busy wait
    }
}
