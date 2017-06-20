
import std.socket;

import collie.socket.eventloop;
import collie.socket.eventloopgroup;
import collie.utils.timingwheel;

import collie.socket.acceptor;
import collie.socket.tcpsocket;
import collie.socket.timer;
import collie.socket.server.connection;
import collie.socket.server.exception;

@trusted final class TCPServer
{
	alias NewConnection = void delegate(EventLoop,Socket);
	alias OnAceptorCreator = void delegate(Acceptor);

	this(EventLoop loop,EventLoopGroup group)
	{
		_loop = loop;
		_group = group;
	}

	@property acceptor(){return _acceptor;}
	@property eventLoop(){return _loop;}
	@property bindAddress(){return _bind;}
	@property group(){return _group;}

	void bind(Address addr, OnAceptorCreator ona = null)
	{
		if(_acceptor !is null)
			throw new SocketBindException("the server is areadly binded!");
		_bind = addr;
		_acceptor = new Acceptor(_loop,addr.addressFamily);
		if(ona) ona(_acceptor);
		_acceptor.bind(_bind);
	}

	void listen(int block)
	{
		if(_acceptor is null)
			throw new SocketBindException("the server is not bind!");
		if(_cback is null)
			throw new SocketServerException("Please set CallBack frist!");

		_acceptor.setCallBack(&newConnect);
		_loop.post((){
				_acceptor.listen(block);
				_acceptor.start();
			});
	}

	void setNewConntionCallBack(NewConnection cback)
	{
		_cback = cback;
	}


	void close()
	{
		if(_acceptor)
			_loop.post(&_acceptor.close);
	}
protected:
	void newConnect(Socket socket)
	{
		import std.exception;
		EventLoop loop = _loop;
		if(_group)
                    loop = _group.at(index);
                ++ index;
		collectException(_cback(_loop,socket));
	}

private:
	Acceptor _acceptor;
	EventLoop _loop;
	EventLoopGroup _group;
	Address _bind;
	size_t index = 0;
private:
	NewConnection _cback;
}

