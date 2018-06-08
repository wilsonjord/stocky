# Stocky

Stocky is a library to help construct and testing stock trading stratigies (backtesting).

# Installation

- add `stocky.d` to your project
- requires the [dstats](https://code.dlang.org/packages/dstats) library

# Usage

```d
import stocky;

auto records = File(`appl.csv`,"r")
                   .byLine
                   .drop(1) // ignore header
                   .map!(a => a.splitter(",").array)
                   .map!(a => tuple!("time","close")
                                    (Date.fromISOExtString(a[0]),a[4].to!double))
                   .array
                   .sort!((a,b) => a.time < b.time);

auto macdStrategy =
    zip(records.sma!"close"(50),   // fast
        records.sma!"close"(200),  // slow
        zip(records.sma!"close"(50),records.sma!"close"(200))
            .map!(a => a[0]-a[1])
            .sma(50))              // signal
        .array
        .retro
        .slide!(No.withPartial)(2) // use a sliding window of 2
                                   // (size 4 is the other common option)
        .map!(a => tradeAction(a)) // generate signals
        .retro
        .zip(records.drop(1))      // signals start at t=1, so offset records accordingly
        .map!(a => Trade(cast(DateTime)a[1].time,a[1].close,a[0]))
                                   // convert to Trade type, so can use
                                   // other stocky lib functions
        .drop(200)                 // allow moving averages to become
                                   // "fully calculated"
        .filter!(a => a.action!=Action.none)
                                   // only process buy or sell
        .array
        .completedOnly;            // complete trades only
                                   // i.e. starts with buy, ends with sell

// display result metrics
writeln ("50-200-50 sma macd metrics (Apple stocks)");
auto appleRes = macdStrategy.results;
writefln ("win rate (%%): %0.2f",appleRes.winRate*100);
writefln ("loss rate (%%): %0.2f",appleRes.lossRate*100);
writefln ("average win (%%): %0.2f",appleRes.wins.mean*100);
writefln ("average loss (%%): %0.2f",appleRes.losses.mean*100);
writefln ("profit factor: %0.2f",(appleRes.winRate*appleRes.wins.mean) /
                                 (appleRes.lossRate*appleRes.losses.mean));
                   
```

The above will produce the following console output:

```
50-200-50 sma macd metrics (Apple stocks)
win rate (%): 72.73
loss rate (%): 27.27
average win (%): 17.87
average loss (%): 28.80
profit factor: 1.65
```