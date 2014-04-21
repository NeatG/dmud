import std.stdio;
import std.socket;
import std.algorithm;
class Client {
 Socket socket;
 this (Socket sock) {
  this.socket = sock;
 }
}
void main() {
    Socket server = new TcpSocket();
    server.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, true);
    server.blocking(false);
    server.bind(new InternetAddress(8080));
    server.listen(1);
	SocketSet checkRead = new SocketSet();
    Socket[] clients;
    while(true) {
	  checkRead.reset(); //Reset checkRead and add server socket
	  checkRead.add(server);
	  if (Socket.select(checkRead,null,null,dur!"hnsecs"(0)) > 0) {
        Socket client = server.accept();
		clients ~= client;
		writefln("Client connected!");
	  }
	  foreach (int i, Socket c; clients) {
	   checkRead.reset();
	   checkRead.add(c);
	   if (Socket.select(checkRead,null,null,dur!"hnsecs"(0)) > 0) {
	    char[1024] buffer;
        auto received = c.receive(buffer);
		if (received == 0) { //They closed the connection
		 writefln("Removing %d",i);
		 clients = remove(clients,i);
		} else {
	     writefln("The client said:\n%s", buffer[0.. received]);
		}
	   }
	  }
    }
}
