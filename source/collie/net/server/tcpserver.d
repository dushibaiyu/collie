﻿/*
 * Collie - An asynchronous event-driven network framework using Dlang development
 *
 * Copyright (C) 2015-2017  Shanghai Putao Technology Co., Ltd 
 *
 * Developer: putao's Dlang team
 *
 * Licensed under the Apache-2.0 License.
 *
 */
module collie.net.server.tcpserver;

import std.socket;

import kiss.net.TcpListener;
import kiss.net.TcpStream;
import kiss.timingwheel;
import kiss.net.Timer;
import kiss.event;
import kiss.event.task;

import collie.net.server.connection;
import collie.net.server.exception;

@trusted final class TCPServer
{
	alias NewConnection = ServerConnection delegate(EventLoop,Socket);
	alias OnAceptorCreator = void delegate(kiss.net.TcpListener.TcpListener);

	this(EventLoop loop)
	{
		_loop = loop;
	}

	@property tcpListener(){return _TcpListener;}
	@property eventLoop(){return _loop;}
	@property bindAddress(){return _bind;}
	@property timeout(){return _timeout;}

	void bind(Address addr, OnAceptorCreator ona = null)
	{
		if(_TcpListener !is null)
			throw new SocketBindException("the server is areadly binded!");
		_bind = addr;
		_TcpListener = new TcpListener(_loop,addr.addressFamily);
		if(ona) ona(_TcpListener);
		_TcpListener.bind(_bind);
	}

	void listen(int block)
	{
		if(_TcpListener is null)
			throw new SocketBindException("the server is not bind!");
		if(_cback is null)
			throw new SocketServerException("Please set CallBack frist!");

		_TcpListener.setReadHandle(&newConnect);
		_loop.postTask(newTask((){
				_TcpListener.listen(block).watch;
			}));
	}

	void setNewConntionCallBack(NewConnection cback)
	{
		_cback = cback;
	}

	void startTimeout(uint s)
	{
		if(_wheel !is null)
			throw new SocketServerException("TimeOut is runing!");
		_timeout = s;
		if(_timeout == 0)return;

		uint whileSize;uint time; 
		enum int[] fvka = [40,120,600,1000,uint.max];
		enum int[] fvkb = [50,60,100,150,300];
		foreach(i ; 0..fvka.length ){
			if(s <= fvka[i]){
				whileSize = fvkb[i];
				time = _timeout * 1000 / whileSize;
				break;
			}
		}
		_wheel = new TimingWheel(whileSize);
		_timer = new Timer(_loop);
		_timer.setTimerHandle(() nothrow {_wheel.prevWheel();});
		//_timer.start(time);
		_loop.postTask(newTask((){ _timer.start(time);}));
	}

	void close()
	{
		if(_TcpListener)
			_loop.postTask(newTask(&_TcpListener.close));
	}
protected:
	void newConnect(EventLoop loop, Socket socket) nothrow
	{
		catchAndLogException((){
			import std.exception;
			ServerConnection connection;
			collectException(_cback(loop,socket),connection);
			if(connection is null) return;
			if(connection.active() && _wheel)
				_wheel.addNewTimer(connection);
		}());
	}

private:
	kiss.net.TcpListener.TcpListener _TcpListener;
	EventLoop _loop;
	Address _bind;
private:
	NewConnection _cback;
private:
	TimingWheel _wheel;
	Timer _timer;
	uint _timeout;
}

