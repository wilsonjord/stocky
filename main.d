module main;

import std.stdio;

import stocky;

import std.typecons : Tuple, tuple;
import std.array : appender;
import std.datetime.stopwatch;
import std.datetime;

import std.algorithm;
import std.range;
import std.conv : to;

import std.traits;

void main(){

    import std.csv;
    import std.file : readText;

    auto records = File("appl.csv","r")
                       .byLine
                       .drop(1) // ignore header
                       .map!(a => a.splitter(",").array)
                       .map!(a => tuple!("time","close")
                                        (Date.fromISOExtString(a[0]),a[4].to!double))
                       .array
                       .sort!((a,b) => a.time < b.time);    // sort by time, not required if you know your data is already sorted

//    records.sma!"close" (200)
//           .drop(199)
//           .take(10)
//           .writeln; // 24.11125,24.065,24.02065...
//
//    // with time stamp
//    zip(records.map!(a => a.time),records.sma!"close"(200))
//        .drop(199)
//        .take(10)
//        .each!(a => writeln(a[0]," @ ",a[1])); // 1985-Jun-21 @ 24.1112
//                                               // 1985-Jun-24 @ 24.065
//                                               // 1985-Jun-25 @ 24.0206
//
//    zip(records.map!(a => a.time),
//        records.ema!"close"(50),
//        records.sma!"close"(200),
//        zip(records.ema!"close"(50),records.sma!"close"(200)).map!(a => a[0]-a[1]),
//        zip(records.ema!"close"(50),records.sma!"close"(200)).map!(a => a[0]-a[1]).ema(50))
//        .take(10)
//        .writeln;


    auto fast = records.ema!"close"(50);
    auto slow = records.sma!"close"(200);
    auto signalLine = zip(fast,slow).map!(a => a[0]-a[1]).ema(50);

    auto signals = zip(fast,slow,signalLine).map!(a => tuple!("fast","slow","signal")(a[0],a[1],a[2]))
                                            .signals;

    signals.take(10).each!(a => a.writeln);
    //macd(records.ema!"close"(50),records.map!(a => a.close).sma(200));

    // [1,2,3,4].macd2(1,1,1).writeln; / error

    //alias Tuple!(Date,"time",
	return;
}
