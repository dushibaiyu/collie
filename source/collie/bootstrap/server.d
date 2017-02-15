/*
 * Collie - An asynchronous event-driven network framework using Dlang development
 *
 * Copyright (C) 2015-2016  Shanghai Putao Technology Co., Ltd 
 *
 * Developer: putao's Dlang team
 *
 * Licensed under the Apache-2.0 License.
 *
 */
module collie.bootstrap.server;

import collie.socket;
import collie.channel;
import collie.bootstrap.serversslconfig;
public import collie.bootstrap.exception;

import std.exception;

final class ServerBootstrap(PipeLine)
{
    this()
    {
        _loop = new EventLoop();
    }

    this(EventLoop loop)
    {
        _loop = loop;
    }

    auto pipeline(DSharedRef!(shared AcceptPipelineFactory) factory)
    {
        _acceptorPipelineFactory = factory;
        return this;
    }

    auto setSSLConfig(ServerSSLConfig config)
    {
	       _sslConfig = config;
	       return this;
    }

    auto childPipeline(DSharedRef!(shared PipelineFactory!PipeLine) factory)
    {
        _childPipelineFactory = factory;
        return this;
    }

    auto group(EventLoopGroup group)
    {
        _group = group;
        return this;
    }

    auto setReusePort(bool ruse)
    {
        _rusePort = ruse;
        return this;
    }

    /**
            The Value will be 0 or 5s ~ 1800s.
            0 is disable, 
            if(value < 5) value = 5;
            if(value > 3000) value = 1800;
        */
    auto heartbeatTimeOut(uint second)
    {
        _timeOut = second;
        _timeOut = _timeOut < 5 ? 5 : _timeOut;
        _timeOut = _timeOut > 1800 ? 1800 : _timeOut;

        return this;
    }

    void bind(Address addr)
    {
        _address = addr;
    }

    void bind(ushort port)
    {
        _address = new InternetAddress(port);
    }

    void bind(string ip, ushort port)
    {
        _address = new InternetAddress(ip, port);
    }

    void stopListening()
    {
		if (!_listening)
            return;
		scope(exit)_listening = false;
        auto next = _mainAccept._next;
        while(next)
        {
            auto accept = next;
            next = next._next;
            accept.stop();
        }
        _mainAccept.stop();

    }

	void stop()
	{
		if(!_isLoopWait) return;
		scope(exit) _isLoopWait = false;
		_group.stop();
		_loop.stop();
	}

    void join()
    {
		if (!_isLoopWait)
            return;
        if (_group)
            _group.wait();
    }

    void waitForStop()
    {
		if(_isLoopWait)
			throw new ServerIsRuningException("server is runing!");
		if(!_listening)
			startListening();
		_isLoopWait = true;
		if(_group)
			_group.start();
		_loop.run();
    }

	void startListening()
	{
		if (_listening)
			throw new ServerIsListeningException("server is listening!");
		if (_address is null || _childPipelineFactory is null)
			throw new ServerStartException("the address or childPipelineFactory is null!");

		_listening = true;
		uint wheel, time;
		bool beat = getTimeWheelConfig(wheel, time);
		_mainAccept = creatorAcceptor(_loop);
		_mainAccept.initialize();
		if (beat)
			_mainAccept.startTimingWhile(wheel, time);
		if (_group)
		{
			foreach (loop; _group)
			{
				auto acceptor = creatorAcceptor(loop);
                acceptor._next = _mainAccept._next;
                _mainAccept._next = acceptor;
				acceptor.initialize();
				if (beat)
					acceptor.startTimingWhile(wheel, time);
			}
		}
		trace("server _listening!");
	}

	EventLoopGroup group(){return _group;}

	@property EventLoop eventLoop(){return _loop;}

	@property Address address(){return _address;}
	
protected:
    auto creatorAcceptor(EventLoop loop)
    {
        auto acceptor = collieAllocator.make!Acceptor(loop, _address.addressFamily == AddressFamily.INET6);
		if(_rusePort)
        	acceptor.reusePort = _rusePort;
        acceptor.bind(_address);
        acceptor.listen(1024);
		{
			Linger optLinger;
			optLinger.on = 1;
			optLinger.time = 0;
			acceptor.setOption(SocketOptionLevel.SOCKET, SocketOption.LINGER, optLinger);
		}
        auto accept = DSharedRef!Acceptor(collieAllocator,acceptor);
        DSharedRef!AcceptPipeline pipe = void;
        if (!_acceptorPipelineFactory.isNull)
            pipe = _acceptorPipelineFactory.newPipeline(accept);
        else
            pipe = AcceptPipeline.create();

        SSL_CTX* ctx = null;
		version(USE_SSL)
        {
            if (_sslConfig)
            {
                ctx = _sslConfig.generateSSLCtx();
                if (!ctx)
					throw new SSLException("Can not gengrate SSL_CTX");
            }
        }

        return collieAllocator.make!(ServerAcceptorImpl!(PipeLine))(accept, pipe, _childPipelineFactory,
            ctx);
    }

    bool getTimeWheelConfig(out uint whileSize, out uint time)
    {
        if (_timeOut == 0)
            return false;
        if (_timeOut <= 40)
        {
            whileSize = 50;
            time = _timeOut * 1000 / 50;
        }
        else if (_timeOut <= 120)
        {
            whileSize = 60;
            time = _timeOut * 1000 / 60;
        }
        else if (_timeOut <= 600)
        {
            whileSize = 100;
            time = _timeOut * 1000 / 100;
        }
        else if (_timeOut < 1000)
        {
            whileSize = 150;
            time = _timeOut * 1000 / 150;
        }
        else
        {
            whileSize = 180;
            time = _timeOut * 1000 / 180;
        }
        return true;
    }

private:
    DSharedRef!(shared AcceptPipelineFactory) _acceptorPipelineFactory;
    DSharedRef!(shared PipelineFactory!PipeLine) _childPipelineFactory;

    ServerAcceptorImpl!(PipeLine) _mainAccept;
    EventLoop _loop;

    EventLoopGroup _group;

	bool _listening = false;
    bool _rusePort = true;
	bool _isLoopWait = false;
    uint _timeOut = 0;
    Address _address;

    ServerSSLConfig _sslConfig = null;
}

//private:

import std.functional;
import collie.utils.timingwheel;
import collie.utils.memory;

final class ServerAcceptorImpl(PipeLine) : InboundHandler!(Socket)
{
    alias TimerWheel = ITimingWheel!IAllocator;

    this(ref DSharedRef!Acceptor acceptor,ref DSharedRef!AcceptPipeline pipe,
      ref DSharedRef!(shared PipelineFactory!PipeLine) clientPipeFactory, SSL_CTX* ctx = null)
    {
        _acceptor = acceptor;
        _pipeFactory = clientPipeFactory;
        auto sref = DSharedRef!(ServerAcceptorImpl!(PipeLine))(collieAllocator,this);
        pipe.addBack!(ServerAcceptorImpl!(PipeLine))(sref);
        pipe.finalize();
        _pipe = pipe;
        auto asyn = acceptor.castTo!AsyncTransport();
        _pipe.transport(asyn);
        _acceptor.setCallBack(&acceptCallBack);
        _sslctx = ctx;
		_list = collieAllocator.make!(ServerConnectionImpl!PipeLine)();
		version(USE_SSL)
			_sharkList = collieAllocator.make!SSLHandShark();
    }
    ~this(){
        collieAllocator.dispose(_list);
        version(USE_SSL) {
             SSLHandShark sh = _sharkList.next;
             while(sh){
                 SSLHandShark del = sh;
                 sh = del.next;
                  collieAllocator.dispose(del);
             }
             collieAllocator.dispose(_sharkList);
        }
        if(_timer)
			dispose(collieAllocator,_timer);
        if(_wheel)
			dispose(collieAllocator,_wheel);
    }

    pragma(inline, true) void initialize()
    {
        _pipe.transportActive();
    }

    pragma(inline, true) void stop()
    {
        _pipe.transportInactive();
    }

    override void read(Context ctx, Socket msg)
    {
		version(USE_SSL)
        {
            if (_sslctx)
            {
                    auto ssl = SSL_new(_sslctx);
				static if (IOMode == IO_MODE.iocp){
					BIO * readBIO = BIO_new(BIO_s_mem());
					BIO * writeBIO = BIO_new(BIO_s_mem());
					SSL_set_bio(ssl, readBIO, writeBIO);
					SSL_set_accept_state(ssl);
					auto asynssl = collieAllocator.make!SSLSocket(_acceptor.eventLoop, msg, ssl,readBIO,writeBIO);
				} else {
                    if (SSL_set_fd(ssl, msg.handle()) < 0)
                    {
                        error("SSL_set_fd error: fd = ", msg.handle());
                        SSL_shutdown(ssl);
                        SSL_free(ssl);
                        return;
                    }
                    SSL_set_accept_state(ssl);
                    auto asynssl = collieAllocator.make!SSLSocket(_acceptor.eventLoop, msg, ssl);
				}
                    auto shark = collieAllocator.make!SSLHandShark(asynssl, &doHandShark);

					shark.next = _sharkList.next;
					if(shark.next) shark.next.prev = shark;
					shark.prev = _sharkList;
					_sharkList.next = shark;

                    asynssl.start();
            }
            else
            {
                auto asyntcp = collieAllocator.make!TCPSocket(_acceptor.eventLoop, msg);
                startSocket(asyntcp);
            }
        } else
        {
            auto asyntcp = collieAllocator.make!TCPSocket(_acceptor.eventLoop, msg);
            startSocket(asyntcp);
        }
    }

    override void transportActive(Context ctx)
    {
        trace("acept transportActive");
        if (!_acceptor.start())
        {
            error("acceptor start error!");
        }
    }

    override void transportInactive(Context ctx)
    {
        _acceptor.close();
		auto con = _list.next;
		_list.next = null;
		while(con) {
			auto tcon = con;
			con = con.next;
			tcon.close();
		}
        _acceptor.eventLoop.stop();
    }

protected:
    pragma(inline) void remove(ServerConnectionImpl!PipeLine conn)
    {
		conn.prev.next = conn.next;
		if(conn.next)
			conn.next.prev = conn.prev;
        collieAllocator.dispose(conn);
    }

    void acceptCallBack(Socket soct)
    {
        _pipe.read(soct);
    }

    pragma(inline, true) @property acceptor()
    {
        return _acceptor;
    }

    void startTimingWhile(uint whileSize, uint time)
    {
        if (_timer)
            return;
        _timer = collieAllocator.make!Timer(_acceptor.eventLoop);
        _timer.setCallBack(&doWheel);
        _wheel = collieAllocator.make!TimerWheel(whileSize,collieAllocator);
        _timer.start(time);
    }

    void doWheel()
    {
        if (_wheel)
            _wheel.prevWheel();
    }

	version(USE_SSL)
    {
        void doHandShark(SSLHandShark shark, SSLSocket sock)
        {
			shark.prev.next = shark.next;
			if(shark.next) shark.next.prev = shark.prev;
            scope (exit)
                collieAllocator.dispose(shark);
            if (sock)
            {
                sock.setHandshakeCallBack(null);
                startSocket(sock);
            }
        }
    }

    void startSocket(TCPSocket sock)
    {
        auto tsock = DSharedRef!(TCPSocket)(collieAllocator,sock);
        auto pipe = _pipeFactory.newPipeline(tsock);
        if (pipe.isNull())
        {
            collieAllocator.dispose(sock);
            return;
        }
        pipe.finalize();
        auto con = collieAllocator.make!(ServerConnectionImpl!PipeLine)(pipe);
        con.serverAceptor = this;

		con.next = _list.next;
		if(con.next)
			con.next.prev = con;
		con.prev = _list;
		_list.next = con;

        con.initialize();
        if (_wheel)
            _wheel.addNewTimer(con);
    }

private:
	ServerConnectionImpl!PipeLine _list;

	version(USE_SSL)
    {
		SSLHandShark _sharkList;
    }

    DSharedRef!Acceptor _acceptor;
    Timer _timer;
    TimerWheel _wheel;
    DSharedRef!AcceptPipeline _pipe;
    DSharedRef!(shared PipelineFactory!PipeLine) _pipeFactory;

    SSL_CTX* _sslctx = null;

    ServerAcceptorImpl!PipeLine _next;
}

@trusted final class ServerConnectionImpl(PipeLine) : IWheelTimer!IAllocator, PipelineManager
{
    this(){}

    this(ref DSharedRef!PipeLine pipe)
    {
        _pipe = pipe;
        _pipe.pipelineManager = this;
    }

    ~this()
    {
    }

    pragma(inline, true) void initialize()
    {
        _pipe.transportActive();
    }

    pragma(inline, true) void close()
    {
        _pipe.transportInactive();
    }

    pragma(inline, true) @property serverAceptor()
    {
        return _manger;
    }

    pragma(inline, true) @property serverAceptor(ServerAcceptorImpl!PipeLine manger)
    {
        _manger = manger;
    }

    override void deletePipeline(PipelineBase pipeline)
    {
        pipeline.pipelineManager = null;
        _pipe.clear();
        stop();
        _manger.remove(this);
    }

    override void refreshTimeout()
    {
        rest();
    }

    override void onTimeOut() nothrow
    {
		collectException(_pipe.timeOut());
    }
private:
	ServerConnectionImpl!PipeLine prev;
	ServerConnectionImpl!PipeLine next;
private:
    ServerAcceptorImpl!PipeLine _manger;
    DSharedRef!PipeLine _pipe;
}

version(USE_SSL)
{
    final class SSLHandShark
    {
        alias SSLHandSharkCallBack = void delegate(SSLHandShark shark, SSLSocket sock);
        this(SSLSocket sock, SSLHandSharkCallBack cback)
        {
            _socket = sock;
            _cback = cback;
            _socket.setCloseCallBack(&onClose);
            _socket.setReadCallBack(&readCallBack);
            _socket.setHandshakeCallBack(&handSharkCallBack);
        }

        ~this()
        {
            if(_socket)
                collieAllocator.dispose(_socket);
        }

    protected:
        void handSharkCallBack()
        {
            trace("the ssl handshark over");
            _cback(this, _socket);
            _socket = null;
        }

        void readCallBack(ubyte[] buffer)
        {
        }

        void onClose()
        {
            trace("the ssl handshark fail");
            _socket.setCloseCallBack(null);
            _socket.setReadCallBack(null);
            _socket.setHandshakeCallBack(null);
            collieAllocator.dispose(_socket);
            _socket = null;
            _cback(this, _socket);
        }

	private:
		this(){}
		SSLHandShark prev;
		SSLHandShark next;
    private:
        SSLSocket _socket;
        SSLHandSharkCallBack _cback;
    }
}
