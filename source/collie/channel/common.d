module collie.channel.common;

public import collie.common;
public import collie.utils.vector;

version(NotUseShared){
    enum userShared = false;
} else {
    enum userShared = true;
}

alias DSharedRef(T) = CSharedRef!(T, userShared);
alias DWeakRef(T) = CWeakRef!(T,userShared);
alias DEnableSharedFromThis(T) = CEnableSharedFromThis!(T,userShared);
alias DScopedRef = CScopedRef;
alias DVector(T) = Vector!(T,IAllocator,false);