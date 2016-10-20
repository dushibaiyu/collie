﻿module collie.codec.http.httpsession;

import collie.codec.http.headers;
import collie.codec.http.httpmessage;
import collie.codec.http.httptansaction;
import collie.codec.http.codec.httpcodec;
import collie.channel;
import collie.codec.http.errocode;

import collie.socket.tcpsocket;
import collie.utils.functional;
import std.socket;


abstract class HTTPSessionController
{
	HTTPTransactionHandler getRequestHandler(HTTPTransaction txn, HTTPMessage msg);

	void attachSession(HTTPSession* session){}
	
	/**
   * Informed at the end when the given HTTPSession is going away.
   */
	void detachSession(const HTTPSession* session){}
	
	/**
   * Inform the controller that the session's codec changed
   */
	void onSessionCodecChange(HTTPSession* session) {}
}

/// HTTPSession will not send any read event
abstract class HTTPSession : HandlerAdapter!(ubyte[]), 
	HTTPTransaction.Transport,
	HTTPCodec.CallBack
{
	alias HVector = HTTPCodec.HVector;
	interface InfoCallback {
		// Note: you must not start any asynchronous work from onCreate()
		void onCreate(HTTPSession);
		//void onIngressError(const HTTPSession, ProxygenError);
		void onIngressEOF();
		void onRequestBegin(HTTPSession);
		void onRequestEnd(HTTPSession,
			uint maxIngressQueueSize);
		void onActivateConnection(HTTPSession);
		void onDeactivateConnection(HTTPSession);
		// Note: you must not start any asynchronous work from onDestroy()
		void onDestroy(HTTPSession);
		void onIngressMessage(HTTPSession,
			HTTPMessage);
		void onIngressLimitExceeded(HTTPSession);
		void onIngressPaused(HTTPSession);
		void onTransactionDetached(HTTPSession);
		void onPingReplySent(int64_t latency);
		void onPingReplyReceived();
		void onSettingsOutgoingStreamsFull(HTTPSession);
		void onSettingsOutgoingStreamsNotFull(HTTPSession);
		void onFlowControlWindowClosed(HTTPSession);
		void onEgressBuffered(HTTPSession);
		void onEgressBufferCleared(HTTPSession);
	}

	this(HTTPSessionController controller,HTTPCodec codec)
	{
		_controller = controller;
		_codec = codec;
		_codec.setCallback(this);
	}

	//HandlerAdapter {
	override void read(Context ctx,ubyte[] msg) {
		_codec.onIngress(msg);
	}

	override void transportActive(Context ctx) {
		TCPSocket sock = cast(TCPSocket)context.pipeline.transport;
		if(sock is null){ 
			_localAddr = new UnknownAddress();
			_peerAddr = _localAddr;
		} else {
			_localAddr = sock.localAddress;
			_peerAddr = sock.remoteAddress;
		}
	}

	override void transportInactive(Context ctx) {
		if(_transaction)
			_transaction.onErro(HTTPErrorCode.REMOTE_CLOSED);
	}

	override void timeOut(Context ctx) {
		if(_transaction){
			_transaction.onErro(HTTPErrorCode.TIME_OUT);
		}
	}

	//HandlerAdapter}
	//HTTPTransaction.Transport, {
	override  void pauseIngress(HTTPTransaction txn){}
	
	override void resumeIngress(HTTPTransaction txn){}
	
	override void transactionTimeout(HTTPTransaction txn){}
	
	override void sendHeaders(HTTPTransaction txn,
		const HTTPMessage headers,
		bool eom)
	{
		HVector tdata;
		_codec.generateHeader(txn.streamID,headers,tdata,eom);
		write(context,tdata.data(true),bind(&writeCallBack,eom));
	}
	
	override size_t sendBody(HTTPTransaction txn,
		ubyte[] data,
		bool eom)
	{
		HVector tdata = HVector(data,false);
		size_t rlen = getCodec.generateBody(txn.streamID,tdata,eom);
		write(context,tdata.data(true),bind(&writeCallBack,eom));

	}
	
	override size_t sendChunkHeader(HTTPTransaction txn,size_t length)
	{
		HVector tdata;
		_codec.generateChunkHeader(txn.streamID,tdata,length);
		write(context,tdata.data(true),bind(&writeCallBack,false));
	}
	
	override size_t sendChunkTerminator(HTTPTransaction txn)
	{
		HVector tdata;
		_codec.generateChunkTerminator(txn.streamID,tdata);
		write(context,tdata.data(true),bind(&writeCallBack,true));
	}
	
	
	override size_t sendEOM(HTTPTransaction txn)
	{
		HVector tdata;
		size_t rlen = _codec.generateEOM(txn.streamID,tdata);
		if(rlen)
			write(context,tdata.data(true),bind(&writeCallBack,true));
	}
	
	//		size_t sendAbort(HTTPTransaction txn,
	//			HTTPErrorCode statusCode);
	
	override void sendWsBinary(HTTPTransaction txn,ubyte[] data)
	{
	}
	
	override void sendWsText(HTTPTransaction txn,string data)
	{}
	
	override void sendWsPing(HTTPTransaction txn,ubyte[] data)
	{}
	
	override void sendWsPong(HTTPTransaction txn,ubyte[] data)
	{}
	
	override void notifyPendingEgress()
	{}
	
	override void detach(HTTPTransaction txn)
	{}
	
	//		void notifyIngressBodyProcessed(uint32_t bytes);
	//		
	//		void notifyEgressBodyBuffered(int64_t bytes);
	
	override Address getLocalAddress(){
		return _localAddr;
	}
	
	override Address getPeerAddress(){
		return _peerAddr;
	}
	
	
	override HTTPCodec getCodec(){
		return _codec;
	}
	
	override bool isDraining(){}
	//HTTPTransaction.Transport, }


	// HTTPCodec.CallBack {
	override void onMessageBegin(StreamID stream, HTTPMessage msg)
	{
		//_transaction = new HTTPTransaction(_codec.getTransportDirection,stream,0,this);
	}

	override void onHeadersComplete(StreamID stream,
		HTTPMessage msg){
		_transaction = new HTTPTransaction(_codec.getTransportDirection,stream,0,this);
		setupOnHeadersComplete(_transaction,msg);
	}

	override void onBody(StreamID stream,const ubyte[] data){
		//HTTPTransaction tran = _transactions.get(stream,null);
		if(_transaction)
			_transaction.onIngressBody(data,0);
	}

	override void onChunkHeader(StreamID stream, size_t length){
		if(_transaction)
			_transaction.onIngressChunkHeader(length);
	}

	override void onChunkComplete(StreamID stream){
		if(_transaction)
			_transaction.onIngressChunkComplete();
	}

	override void onMessageComplete(StreamID stream, bool upgrade){
		if(_transaction)
			_transaction.onIngressEOM();
	}

	override void onError(StreamID stream,HTTPErrorCode code){
		//if(_transaction)
		//	_transaction.
		close(context);
	}

	override void onAbort(StreamID stream,
		HTTPErrorCode code){
		close(context);
	}
	
	override void onWsFrame(StreamID,ref WSFrame){

	}
	
	override void onWsPing(StreamID,ref WSFrame){}
	
	override void onWsPong(StreamID,ref WSFrame){}

	override bool onNativeProtocolUpgrade(StreamID stream,
		CodecProtocol protocol,
		string protocolString,
		HTTPMessage msg);
	{}
	// HTTPCodec.CallBack }
protected:
	/**
   * Called by onHeadersComplete(). This function allows downstream and
   * upstream to do any setup (like preparing a handler) when headers are
   * first received from the remote side on a given transaction.
   */
	void setupOnHeadersComplete(HTTPTransaction txn,
		HTTPMessage msg);
		
	void writeCallBack(bool isLast,ubyte[] data,uint size)
	{
		if(isLast && _codec.shouldClose)
			close(context);
		import collie.utils.memory;
		gcFree(data);
	}
protected:
	//HTTPTransaction[HTTPCodec.StreamID] _transactions;
	HTTPTransaction _transaction;
	Address _localAddr;
	Address _peerAddr;
	HTTPCodec _codec;

	HTTPSessionController _controller;
}

