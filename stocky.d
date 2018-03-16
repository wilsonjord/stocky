module stocky;

import std.typecons : Tuple, tuple;
import std.datetime;
import std.stdio;
import std.conv : to;
import std.algorithm;
import std.range;
import std.format : format;

import dstats : mean;

alias Symbol = Tuple!(string,"exchange",string,"name");

alias Record = Tuple!(Symbol,"symbol",DateTime,"time",double,"open",
                      double,"high",double,"low",double,"close",int,"volumn");

auto get(string field) (Record rec) {
    mixin ("return rec." ~ field ~ ";");
}

unittest {
    auto a = Record (Symbol("ABC","ABC"),DateTime.init,1,2,3,4,5);
    assert (a.get!"close"==4);
}

private __gshared Record[] records;
void stockyInit(string filePath) {
    import std.file : read;
    import std.concurrency;
    import std.parallelism;
    import core.atomic;

    auto data = cast(string) filePath.read;
    shared int lineCount=0;
    auto l = data.length/2;
    foreach (slice; [data[0..l],data[l..$]].parallel) {
        auto c = slice.count('\n');
        lineCount.atomicOp!"+="(c);
    }
    records.length = lineCount;

    foreach (i, line; data.splitter("\n").parallel) {
        if (!line.empty) {
            auto tokens = line.splitter(",");
            Record record;
            foreach (token; tokens.enumerate (0)){
                switch (token.index) {
                    default: break;
                    case 0: record.symbol.exchange = token.value; break;
                    case 1: record.symbol.name = token.value; break;
                    case 2: record.time = Date.fromISOString (token.value).to!DateTime; break;
                    case 3: record.open = token.value.to!double; break;
                    case 4: record.high = token.value.to!double; break;
                    case 5: record.low = token.value.to!double; break;
                    case 6: record.close = token.value.to!double; break;
                    case 7: record.volumn = token.value[0..$-1].to!int; break;
                }
            }
            records[i] = record;
        }
    }
}

auto toDateTime (string s) {
    if (s.canFind("T")){
        return DateTime.fromISOString (s);
    } else {
        return Date.fromISOString(s).to!DateTime;
    }
}

auto all (Symbol s) {
    return records.filter!(a => a.symbol==s);
}

auto between (Symbol s, string startDate, string endDate) {
    return records.filter!(a => a.symbol==s)
                  .filter!(a => a.time >= startDate.toDateTime)
                  .filter!(a => a.time <= endDate.toDateTime);
}

auto between(T) (T data, string start, string end) {
    return data.between (start.toDateTime,end.toDateTime);
}

auto between(T) (T data, DateTime start, DateTime end) {
    return data.filter!(a => a.time >= start)
               .filter!(a => a.time <= end);
}

auto at (Symbol s, DateTime time) {
    return records.filter!(a => a.symbol==s && a.time == time).front;
    assert (0);
}

auto getSymbols() {
    return records.map!(a => a.symbol).array.sort.uniq;
}

alias ReturnType = Tuple!(DateTime,"time",double,"value");

auto sma(string field="close") (Symbol s, int period) {
    auto data = records.filter!(a => a.symbol==s).array.sort!((a,b) => a.time > b.time);
    return data.sma!field (period);
    //return data.map!(a => ReturnType (a.time,data.find!(b => b.time==a.time).take(period).map!(c => c.get!field).mean));
}

auto sma(string field="close",T) (T data, int period){
    return data.map!(a => ReturnType (a.time,data.find!(b => b.time==a.time).take(period).map!(c => c.get!field).mean));
}

auto ema(string field="close") (Symbol s, int period) {
    auto data = records.filter!(a => a.symbol==s).array.sort!((a,b) => a.time > b.time);
    return data.ema!field(period);
    //return data.enumerate.map!(a => ReturnType(a.value.time,data.drop(a.index).retro.map!(c => c.get!field).fold!((a,b) => a+(2.0/(period+1))*(b-a))));
}

auto ema(string field="close", T) (T data, int period) {
    return data.enumerate.map!(a => ReturnType(a.value.time,data.drop(a.index).retro.map!(c => c.get!field).fold!((a,b) => a+(2.0/(period+1))*(b-a))));
}

enum Action {buy,sell}
alias Trade = Tuple!(DateTime,"time",Action,"action",double,"price");

auto macdStrat(string field="close") (Symbol s, int fastPeriod, int slowPeriod) {
    auto fast = s.ema!field (fastPeriod).retro;
    auto slow = s.sma!field (slowPeriod).retro;

    assert (fast.count == slow.count);
    assert (fast.map!(a => a.time).equal(slow.map!(b => b.time)));

    auto rng = zip(fast,slow);
    enum Fast=0;
    enum Slow=1;

    Tuple!(DateTime,Action)[] actions;
    while (true) {
        auto slice = rng.take(2).array;
        if (slice.count < 2) break;

        if (slice[0][Fast].value >= slice[0][Slow].value) {
            if (slice[1][Fast].value < slice[1][Slow].value) {
                // sell
                actions ~= Tuple!(DateTime,Action)(slice[1][Fast].time,Action.sell);
            }
        }

        if (slice[0][Fast].value <= slice[0][Slow].value) {
            if (slice[1][Fast].value > slice[1][Slow].value) {
                // buy
                actions ~= Tuple!(DateTime,Action)(slice[1][Fast].time,Action.buy);
            }
        }
        rng.popFront;

    }
    auto tmp = actions.sort!((a,b) => a[0] < b[0]);
    if (tmp.front[1] == Action.sell) tmp.popFront;
    if (tmp.back[1] == Action.buy) tmp.popBack;


    return tmp.chunks(2).map!(a => tuple(Trade(a[0][0],Action.buy,s.at(a[0][0]).get!field),
                                         Trade(a[1][0],Action.sell,s.at(a[1][0]).get!field)));
}

auto returns(T) (T trades) {
    return trades.map!(a => a[1].price - a[0].price).sum;
}
