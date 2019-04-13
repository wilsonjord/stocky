import std.stdio;

 

import fastcsv;

import stocky;

 

import std.algorithm;

import std.range;

import std.conv : to;

 

auto weightedReturns(T) (T trades) {

    auto t = trades.sort!((a,b) => a.time < b.time).array;

    if (t.front.action == Action.sell) t.popFront;

    if (t.back.action == Action.buy) t.popBack;

 

    import dstats;

 

    return tuple(t.wins.weighted*t.winRate,t.wins.weighted,t.wins.mean,t.wins.median,t.winRate,t.count);

}

 

void selected(string file) {

    auto data = csvFromUtf8File (file).drop(1);

 

    Trade[][string] trades;

 

    foreach (row; data) {

        import std.datetime;

 

        if (row[0] !in trades) trades[row[0]] = Trade[].init;
        
        trades[row[0]] ~= Trade(DateTime(Date.fromISOString(row[1].replace("/",""))),

                                row[2].to!double,

                                (row.back=="buy") ? Action.buy : Action.sell);

 

    }

 

    trades.byKey

          .map!(a => trades[a].map!(b => tuple!("symbol","trade")(a,b)).array)

          .joiner

          .array

          .sort!((a,b) => a.trade.time > b.trade.time)

          .filter!(a => a.trade.action==Action.buy)

          .take(30)

          .map!(a => tuple(a,trades[a.symbol].weightedReturns))

          .array

          .multiSort!((a,b) => a[0].trade.time > b[0].trade.time, (a,b) => a[1][0] > b[1][0])

          .each!(a => writeln (format("%s\t%s\t%s\t%s\t%s",
                                       a[0].symbol,
                                       a[0].trade.time,
                                       a[0].trade.price,
                                       a[0].trade.action,
                                       a[1])));
 

    /* double[string] selectionMetric;

    foreach (symbol; trades.keys)

        selectionMetric[symbol] = symbols.map!(a => format("%s:%s",a,trades[a].wins.weighted)).joiner("\t").writeln;

    } */

    

    return; 

}