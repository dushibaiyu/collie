module collie.common;

public import smartref;
public import std.experimental.allocator;

alias CSharedRef(T, bool isShared = true) = ISharedRef!(IAllocator,T,isShared);
alias CWeakRef(T, bool isShared = true) = IWeakRef!(IAllocator,T,isShared);
alias CEnableSharedFromThis(T, bool isShared = true) = IEnableSharedFromThis!(IAllocator,T,isShared);
alias CScopedRef(T) = IScopedRef!(IAllocator,T);

shared static this(){
	_collieAllocator = allocatorObject(SmartGCAllocator.instance);
}

@property IAllocator collieAllocator() nothrow 
{
	return _collieAllocator;
}


@property void collieAllocator(IAllocator a) nothrow 
{
	assert(a);
	_collieAllocator = a;
}


private:
__gshared IAllocator _collieAllocator;