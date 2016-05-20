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
module collie.utils.timingwheel;

import std.container.array;

import std.stdio;

final class TimingWheel
{
    this(uint wheelSize)
    {
        if (wheelSize == 0)
            wheelSize = 2;
        _list = new NullWheelTimer[wheelSize];
        for (int i = 0; i < wheelSize; ++i)
        {
            _list[i] = new NullWheelTimer();
        }
    }

    pragma(inline)
    void addNewTimer(WheelTimer tm) nothrow
    {
        NullWheelTimer timer = _list[getPrev()];
        tm._next = timer._next;
        tm._prev = timer;
        if (timer._next)
            timer._next._prev = tm;
        timer._next = tm;
        tm._manger = this;
    }

    void prevWheel(uint size = 1) nothrow
    {
        if (size == 0)
            return;
        foreach (i; 0 .. size)
        {
            NullWheelTimer timer = doNext();
            timer.onTimeOut();
        }
    }

protected:
    size_t getPrev() const nothrow
    {
        if (_now == 0)
            return (_list.length - 1);
        else
            return (_now - 1);
    }

    pragma(inline)
    NullWheelTimer doNext() nothrow
    {
        ++_now;
        if (_now == _list.length)
            _now = 0;
        return _list[_now];
    }

    pragma(inline)
    void rest(WheelTimer tm) nothrow
    {
        remove(tm);
        addNewTimer(tm);
    }

    pragma(inline)
    void remove(WheelTimer tm) nothrow
    {
        tm._prev._next = tm._next;
        if (tm._next)
            tm._next._prev = tm._prev;
        tm._manger = null;
        tm._next = null;
        tm._prev = null;
    }

private:
    NullWheelTimer[] _list;
    size_t _now;
}

abstract class WheelTimer
{
    void onTimeOut() nothrow;

    pragma(inline)
    final void rest() nothrow
    {
        if (_manger) 
        {
            _manger.rest(this);
        }
    }

    pragma(inline)
    final void stop() nothrow
    {
        if (_manger) 
        {
            _manger.remove(this);
        }
    }

    pragma(inline,true)
    final bool isActive() const nothrow
    {
        return _manger !is null;
    }

    pragma(inline,true)
    final @property oneShop()
    {
        return _oneShop;
    }

    pragma(inline)
    final @property oneShop(bool one)
    {
        _oneShop = one;
    }

private:
    WheelTimer _next = null;
    WheelTimer _prev = null;
    TimingWheel _manger = null;
    bool _oneShop = false;
}

private:

class NullWheelTimer : WheelTimer
{
    override void onTimeOut() nothrow
    {
        WheelTimer tm = _next;
        while (tm)
        {
            tm.onTimeOut();
            auto timer = tm._next;
            if (tm.oneShop())
            {
                tm.stop();
            }
            tm = timer;
        }
    }
}

unittest
{
    import std.datetime;
    import std.stdio;
    import std.conv;
    import core.thread;

    class TestWheelTimer : WheelTimer
    {
        this()
        {
            time = Clock.currTime();
        }

        override void onTimeOut() nothrow
        {
            try
            {
                writeln("\nname is ", name, " \tcutterTime is : ",
                    Clock.currTime().toSimpleString(), "\t new time is : ", time.toSimpleString());
            }
            catch
            {
            }
            //       assert();
        }

        string name;
    private:
        SysTime time;
    }

    writeln("start");
    TimingWheel wheel = new TimingWheel(5);
    TestWheelTimer[] timers = new TestWheelTimer[5];
    foreach (tm; 0 .. 5)
    {
        timers[tm] = new TestWheelTimer();
    }

    int i = 0;
    foreach (timer; timers)
    {
        timer.name = to!string(i);
        wheel.addNewTimer(timer);
        writeln("i  = ", i);
        ++i;

    }
    writeln("prevWheel(5) the _now  = ", wheel._now);
    wheel.prevWheel(5);
    Thread.sleep(2.seconds);
    timers[4].stop();
    writeln("prevWheel(5) the _now  = ", wheel._now);
    wheel.prevWheel(5);
    Thread.sleep(2.seconds);
    writeln("prevWheel(3) the _now  = ", wheel._now);
    wheel.prevWheel(3);
    assert(wheel._now == 3);
    timers[2].rest();
    timers[4].rest();
    writeln("rest prevWheel(2) the _now  = ", wheel._now);
    wheel.prevWheel(2);
    assert(wheel._now == 0);

    foreach (u; 0 .. 20)
    {
        Thread.sleep(2.seconds);
        writeln("prevWheel() the _now  = ", wheel._now);
        wheel.prevWheel();
    }

}
