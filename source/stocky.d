// Written in the D programming language
// Jordan K. Wilson https://wilsonjord.github.io/

/++
This module provides technical analysis functionality.

Author: $(HTTP wilsonjord.github.io, Jordan K. Wilson)

+/

module stocky;

import std.typecons : Tuple, tuple, Nullable;
import std.datetime;
import std.stdio;
import std.conv : to;
import std.algorithm;
import std.range;
import std.format : format;
import std.traits;
import std.math : isNaN, abs;

import dstats : mean, median, stdev;

version(unittest) import std.math : approxEqual, feqrel;

enum AnnualTradingDays = 252;

auto isNaN (int x) { return true; }

auto convertRange(string field="", Range) (Range rng) {
    static if (!field.empty) {
        static assert (hasMember!(ElementType!Range,field));
        return rng.map!("a." ~ field).map!(a => a.to!double);
    } else {
        return rng.map!(a => a.to!double);
    }
}

unittest {
    auto a = iota(10); // 0 - 9
    assert (a.convertRange.equal(a));

    auto b = a.map!(a => tuple!("myField")(a));
    assert (b.convertRange!"myField".equal(a));

    static assert (!__traits(compiles,b.convertRange!"myVar"));
}

alias Symbol = Tuple!(string,"exchange",string,"name");

/++
    Main data type to store EOD data for a stock
+/
alias EODRecord = Tuple!(DateTime,"time",double,"open",double,"high",double,"low",double,"close",size_t,"volumn");

auto tradify(T) (T rng) {
	ElementType!T[] rvalue;
	if (rng.empty) return rvalue;
	if (rng.count==1) return rvalue;
	if (rng.count==2 && rng.front.action!=Action.buy) return rvalue;

	rvalue = rng;

	if (rvalue.front.action==Action.sell) rvalue.popFront;
	if (rvalue.back.action==Action.buy) rvalue.popBack;

	return rvalue;
}


auto createSMA(T) (T rng, int period) {
    struct SMA(Range) if (isNumeric!(ElementType!Range)) {
        Range rng;
        double period;

        import std.container : DList;
        DList!(ElementType!Range) buffer;

        double currentResult;
        this (Range r, int p) {
            rng=r;
            period=p;
            currentResult=r.front;

            // prepopulate buffer
            buffer.insert (r.front.repeat(p));
        }

        auto front() {
            return currentResult;
        }

        auto popFront() {
            rng.popFront;
            if (!rng.empty){
                currentResult = currentResult + (rng.front / period) - (buffer.back / period);
                buffer.insertFront (rng.front);
                buffer.removeBack;
            }
        }

        auto empty() {
            return rng.empty;
        }
    }
    return SMA!T (rng,period);
}

/++
    Read WorldTrade format JSON file
+/
auto readJson (string fileName) {
    import std.file : readText;
    import std.json : parseJSON;
    import std.datetime.date : Date;
    import std.typecons : tuple;
    

    auto json = fileName.readText.parseJSON;
    return json["history"].object
                          .byKeyValue
                          .filter!(a => !a.value["close"].isNull)
                          .map!(a => tuple!("time","close")(Date.fromISOExtString(a.key),a.value["close"].str.to!double))
                          .array
                          .sort!((a,b) => a.time < b.time);
}


enum RecordSeriesType {daily,monthly}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        type = type of time series of rng

    Returns:
        Annulised volatility
+/

auto annualVolatility(string field="", Range) (Range rng,RecordSeriesType type = RecordSeriesType.daily) {
    import std.math : sqrt, log;
    import dstats : stdev;

    auto logReturn(T) (T t1, T t2, T div=0.0) {
        return log((t2+div) / t1);
    }

    auto myRng = rng.convertRange!field;
    auto numPeriods = (type==RecordSeriesType.daily) ? AnnualTradingDays : 12;

    return 
        myRng.slide!(No.withPartial)(2)
			 .map!(a => logReturn(a.front,a.drop(1).front))
			 .stdev * sqrt(numPeriods.to!double);		
}

unittest {
    assert ([147.82,149.5,149.78,149.86,149.93,150.89,152.39,153.74,152.79,151.23,151.78]
                .annualVolatility
                .approxEqual(0.110477));
}

auto volatility(T) (T records) {
    
	auto numRecords=0;
	auto volatility = 
		records.slide!(No.withPartial)(2)
			.map!(a => tuple!("time","dailyReturn")(a[1].time,a[1].close/a[0].close - 1))
			.filter!(a => a.time.year >= 2016)
			.chunkBy!((a,b) => a.time.year == b.time.year)
			.map!(a => a.map!(b => b.dailyReturn).stdev)
			.tee!(a => numRecords++)
			.enumerate(1)
			.map!(a => a.index * a.value)
			.sum / iota(1,numRecords+1).sum;
}




auto dailyReturns(string field="", Range) (Range rng) {
    auto myRng = rng.convertRange!field;
    return chain([double.nan], myRng.slide!(No.withPartial)(2)
                                .map!(a => (a[1] - a[0]) / a[0].to!double));
}

auto stdDeviation(string field="", Range) (Range rng, size_t period) {
    auto myRng = rng.convertRange!field;
    
    return chain(repeat(double.nan,period-1),
                 myRng.slide!(No.withPartial)(period)
                      .map!(a => a.stdev));
}

auto sharpeRatio(string field="", Range) (Range rng, size_t period) {
    auto myRng = rng.convertRange!field;
    
    return chain(repeat(double.nan,period-1),
                 myRng.dailyReturns
                      .slide!(No.withPartial)(period)
                      .map!(a => a.mean / a.stdev));
}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to average

    Returns:
        A simple moving average range
+/
auto sma(string field="", Range) (Range rng, int period) {
    auto myRng = rng.convertRange!field;
    return chain(repeat(double.nan,period-1),
                 myRng.slide!(No.withPartial)(period)
                      .map!(a => a.mean));

    //return createSMA(myRng,period);
}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to average

    Returns:
        A simple moving average range
+/
auto returns(string field="", Range) (Range rng, int period) {
    auto myRng = rng.convertRange!field;
    return chain(repeat(double.nan,period-1),
                 myRng.slide!(No.withPartial)(period)
                      .map!(a => a.dailyReturns.mean));

    //return createSMA(myRng,period);
}

unittest {
    //[1,1,3,4,6,6,5,7,5,6].sharpeRatio(3).writeln;
    //[1,1,3,4,6,6,5,7,5,6].dailyReturns.writeln;
    //[1,1,3,4,6,6,5,7,5,6].dailyReturns.sma(3).writeln;
    //assert(0);
}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to get the high

    Returns:
        Highest value
+/
auto high(string field="", Range) (Range rng, int period) {
    auto myRng = rng.convertRange!field;
    return chain(repeat(double.nan,period-1),
                 myRng.slide!(No.withPartial)(period)
                      .map!(a => a.maxElement));
}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to get the low

    Returns:
        Lowest value
+/
auto low(string field="", Range) (Range rng, int period) {
    auto myRng = rng.convertRange!field;
    return chain(repeat(double.nan,period-1),
                 myRng.slide!(No.withPartial)(period)
                      .map!(a => a.minElement));
}

///
unittest {
    // using simple arrays
    auto x = [25,85,65,45,95,75,15,35];

    assert (x.sma(3).count == x.length);
    assert (x.sma(3).take(2).all!(a => a.isNaN));
    assert (x.sma(3).drop(2).front.approxEqual((25+85+65) / 3.0));
    assert (x.sma(1).approxEqual(x));

    auto y = [double.nan,double.nan,1,4,9];
    assert (y.sma(3).count == y.length);
    assert (y.sma(3).filter!(a => !a.isNaN)
                    .approxEqual([4.67]));

    // using user type
    auto c = [EODRecord(DateTime(2000,1,1,0,0,0),
                        11,     // open
                        15,     // high
                        10,     // low
                        13,     // close
                        1),     // volumn
              EODRecord(DateTime(2000,1,2,0,0,0),
                        12,
                        16,
                        11,
                        14,
                        1),
              EODRecord(DateTime(2000,1,3,0,0,0),
                        11,
                        15,
                        10,
                        15,
                        1)];

    assert (c.sma!"close"(3)
             .drop(2)
             .front.approxEqual(14));

    assert (c.sma!"open"(3)
             .drop(2)
             .front.approxEqual ((11+12+11) / 3.0));

    assert (c.map!(a => a.open).sma(3).drop(2).equal
           (c.sma!"open"(3).drop(2)));

}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to average
        seed = optional seed, (default value is the first value of rng)

    Returns:
        An exponential moving average range
+/
auto ema(string field="", Range) (Range rng, int period, double seed = double.init) {
    struct EMA(IndexedRange) {
        double currentValue;
        double weighting;
        IndexedRange rng;
        bool hasSeed;
        size_t period;
        size_t startOfData;
        this (IndexedRange r, int p, double seed) {
            rng = r;
            period=p;
            weighting = 2.0 / (period+1);
            hasSeed = !seed.isNaN;
            if (hasSeed) {
                currentValue = seed;
                startOfData = 0;
            } else {
                startOfData = period - 1;
                currentValue = rng.take(period)
                                  .map!(a => a.value)
                                  .mean;
            }
        }

        auto front() {
            if (rng.front.index < startOfData) return double.nan;
            return currentValue;
        }

        auto popFront() {
            rng.popFront;
            if (!rng.empty){
                if (rng.front.index > startOfData) {
                    currentValue += (rng.front.value - currentValue)*weighting;
                }
            }
        }

        auto empty() { return rng.empty; }
    }

    auto myRng = rng.convertRange!field;
    auto nas = myRng.countUntil!(a => !a.isNaN);
    return chain(myRng.take(nas),EMA!(typeof(myRng.enumerate)) (myRng.drop(nas).enumerate,period,seed));
}

/+ auto ema(string field="", Range) (Range rng, int period, double seed = double.init) {
    struct EMA(IndexedRange) {
        double currentValue;
        double weighting;
        IndexedRange rng;
        bool hasSeed;
        size_t period;
        size_t startOfData;
        this (IndexedRange r, int p, double seed) {
            rng = r;
            period=p;
            weighting = 2.0 / (period+1);
            hasSeed = !seed.isNaN;
            if (hasSeed) {
                currentValue = seed;
                startOfData = 0;
            } else {
                startOfData = period - 1;
                currentValue = rng.take(period)
                                  .map!(a => a.value)
                                  .mean;
            }
        }

        auto front() {
            if (rng.front.index < startOfData) return double.nan;
            return currentValue;
        }

        auto popFront() {
            rng.popFront;
            if (!rng.empty){
                if (rng.front.index > startOfData) {
                    currentValue += (rng.front.value - currentValue)*weighting;
                }
            }
        }

        auto empty() { return rng.empty; }
    }

    auto myRng = rng.convertRange!field;
    auto nas = myRng.countUntil!(a => !a.isNaN);
    return chain(myRng.take(nas),EMA!(typeof(myRng.enumerate)) (myRng.drop(nas).enumerate,period,seed));
} +/




///
unittest {
    // http://investexcel.net/how-to-calculate-ema-in-excel/
    auto close = [27.62,27.25,26.74,26.69,26.55,26.7,26.46,26.83,26.89,27.21,27.04,27.25,27.25,27.15,27.61,27.63,27.88,
                  27.91,28.01,27.85,27.45,27.93,27.44,27.5,27.34,27.28,27.55,27.86,27.88,28.03,28.04,28.01,28.05,27.87,
                  27.49,27.76,27.37,27.37,27.81,27.8,27.95,28.15,28.35,28.09,28.14,28,27.87,27.91,27.92,28.14];


    assert (close.ema(26).take(25).all!(a => a.isNaN));
    assert (!close.ema(26).drop(25).front.isNaN);
    close.ema(26).drop(25).map!(a => format("%0.5f",a)).writeln;
    
    assert (close.ema(26).drop(25).map!(a => format("%0.5f",a)).equal(
        [27.2869230769231,27.3064102564103,27.3474169040836,27.3868675037811,27.4345069479455,
               27.4793582851347,27.5186650788284,27.5580232211374,27.5811326121643,27.5743820483002,
               27.5881315262039,27.571973635374,27.5570126253463,27.5757524308762,27.5923633619224,
               27.618854964743,27.6581990414287,27.7094435568784,27.7376329230356,27.7674378916996,
               27.7846647145367,27.7909858467932,27.7998017099937,27.8087052870312,27.83324563614]
               .map!(a => format("%0.5f",a))));

    
    assert (zip(close.ema(26,27.62).take(5),[27.62,27.59259259,27.52943759,27.46725702,27.39931206])
                .all!(a => feqrel(a[0],a[1]) > 11));

    // test based on
    // http://www.dummies.com/personal-finance/investing/stocks-trading/how-to-calculate-exponential-moving-average-in-trading/
    auto b = [22.81,23.09,22.91,
              23.23,22.83,23.05,
              23.02,23.29,23.41,
              23.49,24.6,24.63,
              24.51,23.73,23.31,
              23.53,23.06,23.25,
              23.12,22.8,22.84];
    assert (b.ema(9,22.81)
             .approxEqual([22.81,22.87,22.87,
                           22.95,22.92,22.95,
                           22.96,23.03,23.1,
                           23.18,23.47,23.7,
                           23.86,23.83,23.73,
                           23.69,23.56,23.5,
                           23.42,23.3,23.21]));

    auto c = iota(1,100).map!(a => tuple!("index","value")(a,a));
    assert (c.ema!"value"(10,1)
             .drop(9)
             .take(3).approxEqual([6.24,7.10,7.99]));
}


/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to average
        seed = optional seed, (default value is the first value of rng)

    Returns:
        A double exponential moving average range
+/
auto dema(string field="", Range) (Range rng, int period, double seed = double.init) {
    auto emaRng = rng.ema!field (period,seed).array; // TODO check use of array
    return zip(emaRng,emaRng.ema!field(period))
                .map!(a => 2*a[0] - a[1]);
}

unittest {
    //[7,1,9,3,3,1,4,6,3,7,7,5,2,9,8,9,3,9,9,7,4,7,6,6,3,4,3,6,7,4,9,1].ema(4).writeln;
    //[7,1,9,3,3,1,4,6,3,7,7,5,2,9,8,9,3,9,9,7,4,7,6,6,3,4,3,6,7,4,9,1].dema(4).writeln;
}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        period = number of time periods to average
        seed = optional seed, (default value is the first value of rng)

    Returns:
        A triple exponential moving average range
+/
auto tema(string field="", Range) (Range rng, int period, double seed = double.init) {
    auto emaRng = rng.ema!field (period,seed).array; // TODO check use of array
    return zip(emaRng,emaRng.ema!field(period),emaRng.ema!field(period).ema!field(period))
                .map!(a => 3*a[0] - 3*a[1] + a[2]);
}

unittest {
    //[7,1,9,3,3,1,4,6,3,7,7,5,2,9,8,9,3,9,9,7,4,7,6,6,3,4,3,6,7,4,9,1].ema(4).writeln;
    //[7,1,9,3,3,1,4,6,3,7,7,5,2,9,8,9,3,9,9,7,4,7,6,6,3,4,3,6,7,4,9,1].dema(4).writeln;
    //[7,1,9,3,3,1,4,6,3,7,7,5,2,9,8,9,3,9,9,7,4,7,6,6,3,4,3,6,7,4,9,1].tema(4).writeln;
}

auto createK(Range) (Range rng, int windowSize) if (isNumeric!(ElementType!Range)) {
    return 0.to!(ElementType!Range)
            .repeat(windowSize-1)   // fill result with 0's until t = windowSize
                                    // chain with actual k-range
            .chain(rng.retro        // newest to oldest
                      .slide!(No.withPartial)(windowSize)
                      .map!(a => (a[0] - a.minElement).to!double / (a.maxElement - a.minElement))
                      .retro);      // revert back to oldest to newest
}

unittest {
    auto a = [3,6,5,8,9,2,5,2,8,1,5];
    auto b = a.createK(3);
    assert (a.length==b.length);
    assert (b.drop(2).front.approxEqual((5-3) / (6-3).to!double));  // 0.6667
}

/++
    Params:
        field = define what member to use for calculation
        rng = InputRange
        lookBack = number of periods to look back (typical 14)
        kPeriod = moving average for the K line
                 (use 1 for no moving aveage, a.k.a "fast" K)
        dPeriod = moving average for the D line

    Returns:
        A range of K/D pairs
+/
auto stochasticOscillator(string field="", Range) (Range rng, int lookBack=14, int kPeriod=1, int dPeriod=3) {
    auto myRng = rng.convertRange!field;

    return zip (myRng.createK(lookBack)
                     .sma(kPeriod),     // the k line
                myRng.createK(lookBack)
                     .sma(kPeriod)
                     .sma(dPeriod))     // the d line
                                        // (moving average of the k line)
              .map!(a => tuple!("K","D")(a.expand));
}

///
unittest {
    auto a = [3,6,5,8,9,2,5,2,8,1,5,4];
    a.stochasticOscillator(3)
     .map!(a => [a.K,a.D])
     .approxEqual([[0.000,0.000],[0.000,0.000],
                   [0.667,0.222],[1.000,0.556],
                   [1.000,0.556],[1.000,0.889],
                   [0.000,0.667],[0.429,0.476],
                   [0.000,0.143],[1.000,0.476],
                   [1.000,0.476],[0.000,0.333],
                   [0.571,0.524],[0.750,0.440]]);

    auto b = a.map!(a => tuple!("close")(a));
    b.stochasticOscillator!"close"(3)
     .map!(a => [a.K,a.D])
     .approxEqual([[0.000,0.000],[0.000,0.000],
                   [0.667,0.222],[1.000,0.556],
                   [1.000,0.556],[1.000,0.889],
                   [0.000,0.667],[0.429,0.476],
                   [0.000,0.143],[1.000,0.476],
                   [1.000,0.476],[0.000,0.333],
                   [0.571,0.524],[0.750,0.440]]);

    // slow stocastic
    b.stochasticOscillator!"close"(3,3,3)   // look back range 3
                                            // moving average k
                                            // moving average d
     .map!(a => [a.K,a.D])
     .approxEqual([
        [0.000,0.000],
        [0.000,0.000],
        [0.222,0.074],
        [0.556,0.259],
        [0.889,0.556],
        [0.667,0.704],
        [0.476,0.677],
        [0.143,0.429],
        [0.476,0.365],
        [0.333,0.317],
        [0.524,0.444],
        [0.440,0.433]]);
}

// TODO
// myrng.rsi(14).filter!(a => !a.isNaN) doesn't work
// myrng.rsi(14).array.filter!(a => !a.isNaN) does works
// myrng.rsi(14).drop(14) does works

auto rsi(string field="",Range) (Range rng, int period) {
    auto myRng = rng.convertRange!field;

    auto nas = myRng.countUntil!(a => !a.isNaN);
    auto gainSeed = myRng.changes.drop(nas).take(period).filter!(a => a > 0).sum / period;
    auto lossSeed = myRng.changes.drop(nas).take(period).filter!(a => a < 0).sum.abs / period;

    auto currentGain=gainSeed;
    auto currentLoss=lossSeed;

    auto getGain(T) (T value) {
        auto rvalue = ((period-1)*currentGain + ((value > 0) ? value : 0)) / period;
        currentGain = rvalue;
        return rvalue;
    }

    auto getLoss(T) (T value) {
        auto rvalue = ((period-1)*currentLoss + ((value < 0) ? value.abs : 0)) / period;
        currentLoss = rvalue;
        return rvalue;
    }

    auto gains =  chain(myRng.take(nas),double.nan.repeat(period),[gainSeed],
                        myRng.changes
                             .drop(nas)
                             .drop(period+1)
                             .map!(a => getGain(a)));

    auto losses =  chain(myRng.take(nas),double.nan.repeat(period),[lossSeed],
                        myRng.changes
                             .drop(nas)
                             .drop(period+1)
                             .map!(a => getLoss(a)));

    return zip(gains,losses).map!(a => 100 - (100 / (1 + (a[0] / a[1]))));

    //gains.writeln;
    //losses.writeln;
    //readln;
//    auto firstValueRS = (myRng.drop(nas)
//                              .change
//                              .filter!(a => a > 0)
//                              .sum / period) /
//                        (myRng.drop(nas)
//                              .change
//                              .filter!(a => a < 0)
//                              .sum / period);

    //myRng.drop(nas).cumulativeFold!((a,b) => 100 - (100/(1 + a))(firstValueRS);
    //return chain(myRng.take(nas),EMA!(typeof(myRng.enumerate)) (myRng.drop(nas).enumerate,period,seed));
}

unittest {
    auto a = [44.34,44.0902,44.1497,43.6124,44.3278,44.8264,45.0955,45.4245,45.8433,46.0826,45.8931,46.0328,45.614,46.282,46.282,46.0028,46.0328,46.4116,46.2222,45.6439,46.2122,46.2521,45.7137,46.4515,45.7835,45.3548,44.0288,44.1783,44.2181,44.5672,43.4205,42.6628,43.1314];

    assert (a.rsi(14).drop(14).approxEqual(
        [70.532789483695,66.3185618051723,66.5498299355276,69.4063053388443,66.3551690562718,57.9748557143082,62.929606754597,63.2571475625453,56.0592987152632,62.3770714431804,54.7075730812613,50.4227744114564,39.9898231453766,41.4604819757056,41.8689160925433,45.4632124452868,37.3040420898597,33.0795229943885,37.7729521144349]
    ));

    auto b = a.map!(a => tuple!("close")(a));
    assert (b.rsi!"close"(14).drop(14).approxEqual(
        [70.532789483695,66.3185618051723,66.5498299355276,69.4063053388443,66.3551690562718,57.9748557143082,62.929606754597,63.2571475625453,56.0592987152632,62.3770714431804,54.7075730812613,50.4227744114564,39.9898231453766,41.4604819757056,41.8689160925433,45.4632124452868,37.3040420898597,33.0795229943885,37.7729521144349]
    ));

}

auto changes(string field="",Range) (Range rng) {
    auto myRng = rng.convertRange!field;
    return chain([double.nan],rng.convertRange!field
                                 .slide(2)
                                 .map!(a => a[1]-a[0]));
}

unittest {
    auto a = [1,3,4,7,10];
    assert (a.changes.drop(1).equal([2,1,3,3]));

    auto b = [double.nan,double.nan,1,3,4,7,10];
    assert (b.changes.count==b.count);
    assert (b.changes.endsWith([2,1,3,3]));
}

auto result (double start, double end) {
    return (end - start) / start;
}

auto result(T) (in T trade) pure {
    return result(trade.front.price,trade.back.price);
}

/++
    Given a range of trades, gives the percentage
    increase/decrease of each sequential $(LREF Trade).

    Params:
        trades = A range of $(LREF Trade)'s

    Returns:
        The percentage increase/decrease of trades
+/
auto results(T) (in T trades) pure {
    return trades.chunks(2)
                 .map!(a => a.result);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,2)),4,Action.sell),
                      Trade(DateTime(Date(2000,1,3)),4.5,Action.buy),
                      Trade(DateTime(Date(2000,1,4)),4,Action.sell)];

    assert (trades.results
                  .approxEqual([0.333,-0.111]));
}

auto dayHeld(T) (in T trade) pure {
    return trade.map!(a => (a[1].time - a[0].time).total!"days");
}

/++
    Given a range of trades, return the total number
    of days holding each trade.

    Params:
        trades = A range of $(LREF Trade)'s

+/
auto daysHeld(T) (in T trades) pure {
    return trades.chunks(2)
                 .map!(a => (a[1].time - a[0].time).total!"days")
                 .sum;
}

auto daysHeld2(T) (in T trades) pure {
    return trades.chunks(2)
                 .map!(a => (a[1].time - a[0].time).total!"days");
                 
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),4.5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),4,Action.sell)];
    assert (trades.daysHeld==27);
}


auto averageDaysHeld(T) (in T trades) {
    return trades.daysHeld / (trades.count / 2).to!double;
}

/++
    Given a range of trades, return the
    average number of trades per year.

    Serves as an indication of how "busy"
    a particular trading strategy could be
    during the year.

    Params:
        trades = A range of $(LREF Trade)'s
+/
auto tradesPerYear(T) (in T trades) pure {
    return (trades.count/2).to!double / (((trades.back.time-trades.front.time).total!"days")/365.25);


}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),4.5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),4,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4,Action.sell)
                      ];

    // 3 trades, over 2 years + 1 day
    assert (trades.tradesPerYear
                  .approxEqual(3 / ((365*2+1)/365.25)));
}

/++
    Given a range of trades, return the
    percentage gain/loss of the first trade
    with the last trade.

    Params:
        trades = A range of $(LREF Trade)'s
+/
auto marketReturn(T) (in T trades) pure {
    return result (trades.front.price,trades.back.price);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.8,Action.sell)
                      ];

    assert (trades.marketReturn.approxEqual((4.8-3)/3));
}


auto winlossRate(string type, T) (in T trades, Flag!"weighted" flag, double subtract) pure {
    static assert (type=="win" || type=="loss");
    import std.functional : greaterThan, lessThan;

    static if (type=="win") {
        alias myCompare = greaterThan;
    } else {
        alias myCompare = lessThan;
    }

    if (flag==Yes.weighted) {
        return trades.results
                     .enumerate(1)
                     .map!(a => (myCompare(a.value-subtract,0)) ? a.index : 0)
                     .sum / iota(1,trades.results.count+1).sum.to!double;
    } else {
        return trades.results.count!(a => myCompare(a-subtract,0)) / trades.results.count.to!double;
    }
}

/++
    Given a range of trades, return the
    win rate.

    Params:
        trades = A range of $(LREF Trade)'s
        flag = Whether the results are time weighted (default No)
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto winRate(T) (in T trades, double subtract=0, Flag!"weighted" flag = No.weighted) pure {
    return winlossRate!"win" (trades,flag,subtract);
}

auto winRate(T) (in T trades, Flag!"weighted" flag = No.weighted, double subtract=0) pure {
    return winlossRate!"win" (trades,flag,subtract);
}

auto winRate(T) (in T trades) pure {
    return winlossRate!"win" (trades,No.weighted,0);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell)
                      ];

    // 4 trades, 2 winning, 1 losing
    assert (trades.winRate
                  .approxEqual(2.0 / 4));

    assert (trades.winRate(0.1)             // subtract brokerage of 10%
                  .approxEqual(1.0 / 4));   // only one winner now


    // sequentially, trades go: win, win, loss, draw
    // the wins are given less weighting, as they
    // are the "oldest"
    assert (trades.winRate(Yes.weighted)
                  .approxEqual(0.3));

    assert (trades.winRate(Yes.weighted,0.01) // subtract brokerage of 1%
                  .approxEqual(0.3));         // no change, same number of winners
}




/++
    Given a range of trades, return the
    loss rate.

    Params:
        trades = A range of $(LREF Trade)'s
        flag = Whether the results are time weighted (default No)
        subtract = A percentage to subtract from
                   each result (i.e. brokerage). Default 0
+/
auto lossRate(T) (in T trades, double subtract=0, Flag!"weighted" flag = No.weighted) pure {
    return winlossRate!"loss" (trades,flag,subtract);
}

auto lossRate(T) (in T trades, Flag!"weighted" flag = No.weighted, double subtract=0) pure {
    return winlossRate!"loss" (trades,flag,subtract);
}

auto lossRate(T) (in T trades) pure {
    return winlossRate!"loss" (trades,No.weighted,0);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell)
                      ];

    // 4 trades, 2 winning, 1 losing
    assert (trades.lossRate
                  .approxEqual(1.0 / 4));

    assert (trades.lossRate(0.01)
                  .approxEqual(2.0 / 4));      // two losses now, due to
                                               // brokerage of 1%

    // sequentially, trades go: win, win, loss, draw
    // the loss is given more weighting than wins, as
    // it is "newer"
    assert (trades.lossRate(Yes.weighted)
                  .approxEqual(0.3));

    assert (trades.lossRate(Yes.weighted,0.01) // subtract brokerage of 1%
                  .approxEqual(0.7));          // loss rate increase, as the
                                               // final pair is now a loss
}

auto winslosses(string type,T) (in T trades, double subtract) pure {
    static assert (type=="win" || type=="loss");
    import std.functional : greaterThan, lessThan;

    static if (type=="win") {
        alias myCompare = greaterThan;
    } else {
        alias myCompare = lessThan;
    }

    import std.math : abs;
    return trades.results
                 .filter!(a => myCompare(a-subtract,0))
                 .map!(a => (a-subtract).abs);
}

/++
    Given a range of trades, return the
    winners as a range of results.

    Params:
        trades = A range of $(LREF Trade)'s
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto wins(T) (in T trades, double subtract=0) pure {
    return trades.winslosses!"win"(subtract);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell),
                      Trade(DateTime(Date(2002,2,4)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,5)),4.9,Action.sell)
                      ];

    assert (trades.wins
                  .approxEqual([
                                0.333,   // from the first buy/sell pair (3 and 4)
                                0.1,     // from the second buy/sell pair (5 and 5.5)
                                0.0889   // from the last buy/sell pair (4.5 and 4.9)
                               ]));

    assert (trades.wins(0.01)            // 1% commision
                  .approxEqual([
                                0.333-0.01,
                                0.1-0.01,
                                0.0889-0.01
                               ]));
}

/++
    Given a range of trades, return the
    losers as a range of results.

    Note: losses are expressed as a positive percentage.

    Params:
        trades = A range of $(LREF Trade)'s
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto losses(T) (in T trades, double subtract=0) pure {
    return trades.winslosses!"loss"(subtract);
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell),
                      Trade(DateTime(Date(2002,2,4)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,5)),4.9,Action.sell)
                      ];

    assert (trades.losses
                  .approxEqual([
                                0.0667   // from the third buy/sell pair (4.5 and 4.2)
                               ]));

    assert (trades.losses(0.01)          // 1% commision
                  .approxEqual([
                                 0.0667+0.01,
                                 0.01
                               ]));
}

/++
    Given a range of trades, return the
    profit factor.

    Params:
        trades = A range of $(LREF Trade)'s
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto profitFactor(T) (in T trades, double subtract=0) pure {
    return (trades.wins(subtract).mean * trades.winRate(subtract)) /
           (trades.losses(subtract).mean * trades.lossRate(subtract));
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell),
                      Trade(DateTime(Date(2002,2,4)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,5)),4.9,Action.sell)
                      ];

    assert (trades.profitFactor
                  .approxEqual((0.174*0.6) / (0.067*0.2)));  // avg wins * win rate / avg loss * loss rate

    assert (trades.profitFactor(0.01)
                  .approxEqual((0.164*0.6) / (0.0433*0.4)));
}

auto expectancy(T) (in T trades, double subtract=0) {
    return (trades.wins(subtract).mean * trades.winRate(subtract)) -
           (trades.losses(subtract).mean * trades.lossRate(subtract));
}

/++
    Given a range of trades, return the
    highest count of consecutive losses.

    Params:
        trades = A range of $(LREF Trade)'s
        subtract = A percentage to subtract from
                   each result (i.e. brokerage)
+/
auto maxConsecutiveLosses(T) (in T trades, double subtract=0) {
    return  trades.results
                  .map!(a => a-subtract)
                  .splitter!(a => a >= 0)
                  .maxElement!(a => a.count)
                  .count;
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),

                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),

                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),

                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell),

                      Trade(DateTime(Date(2002,2,4)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,5)),4.9,Action.sell),

                      Trade(DateTime(Date(2002,2,6)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,7)),4.2,Action.sell)
                      ];

    assert (trades.maxConsecutiveLosses==1);
    assert (trades.maxConsecutiveLosses(0.01)==2);
}

auto years(T) (in T trades) pure {
    // assume sorted
    return (trades.back.time - trades.front.time).total!"days" / 365.0;
}



/++
    Given a range of trades and initial capital,
    return the Internal Rate of Return (IRR) assuming
    trades are reinvested.

    Params:
        trades = A range of $(LREF Trade)'s
        startValue = Initial capital

+/
auto IRR(T) (in T trades, double startValue) {
    auto rvalue=startValue;
    foreach (pair; trades.chunks(2)){
        auto buyTrade = pair[0];
        auto sellTrade = pair[1];

        // buy
        import std.math : floor;
        auto brokerage = (rvalue > 1000) ? 30 : 15;
        auto bought = floor((rvalue - brokerage) / buyTrade.price);
        rvalue -= bought*buyTrade.price;
        rvalue -= brokerage;

        // sell
        rvalue += bought*sellTrade.price;
        rvalue -= brokerage;

        writeln (rvalue," ",pair);
    }

    if (rvalue==startValue) return 0;
    if (rvalue<=0) return -1;

    import std.math : pow;
    return pow((rvalue / startValue),1/trades.years)-1;
}


auto annualROI(T) (in T trades, double cost, double brokerage=0) {
    // aim is to have cost remain throughout

    auto rvalue = cost;

    auto tradeValue(T) (T pair) {
        import std.math : floor;
        auto quantity = floor((cost-brokerage) / pair[0].price);
        auto profit = ((pair[1].price * quantity) - brokerage) -     // sell
                      ((pair[0].price * quantity) + brokerage);      // buy

        return tuple!("time","value")(pair[1].time,profit);
    }

    auto flows = trades.chunks(2)
                       .map!(a => tradeValue(a));

    return ((flows.map!(a => a.value).sum+cost) / cost) / trades.years;
}

///
unittest {
    Trade[] trades = [Trade(DateTime(Date(2000,1,1)),3,Action.buy),
                      Trade(DateTime(Date(2000,1,8)),4,Action.sell),
                      Trade(DateTime(Date(2001,5,3)),5,Action.buy),
                      Trade(DateTime(Date(2001,5,23)),5.5,Action.sell),
                      Trade(DateTime(Date(2002,1,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,1,2)),4.2,Action.sell),
                      Trade(DateTime(Date(2002,2,1)),4.5,Action.buy),
                      Trade(DateTime(Date(2002,2,2)),4.5,Action.sell)
                      ];
}

auto profitPerDay (T) (in T trades, double cost, double brokerage=0) {
    // aim is to have cost remain throughout

    auto rvalue = cost;

    auto tradeValue(T) (T pair) {
        import std.math : floor;
        auto quantity = floor((cost-brokerage) / pair[0].price);
        return ((pair[1].price * quantity) - brokerage) -     // sell
               ((pair[0].price * quantity) + brokerage);      // buy
    }

    return trades.chunks(2)
                 .map!(a => tradeValue(a))
                 .sum /
                 trades.daysHeld;
}



auto weighted(T) (T profitRange, double brokerage=0) pure {
     return profitRange.enumerate(1)
                       .map!(a => a.index * (a.value-brokerage))
                       .sum / iota(1,profitRange.count+1).sum;
}

auto staticInvest(T) (in T trades, double invest, double brokerage=0) pure {
    auto rvalue=0.0;
    foreach (pair; trades.chunks(2)) {
        auto buyTrade = pair[0];
        auto sellTrade = pair[1];

        // buy
        import std.math : floor;
        auto bought = floor(invest / buyTrade.price);
        rvalue -= bought * buyTrade.price;
        rvalue -= brokerage;

        // sell
        rvalue += bought*sellTrade.price;
        rvalue -= brokerage;
    }
    return rvalue;
}

enum Action {buy,sell,none}

alias Trade = Tuple!(DateTime,"time",double,"price",Action,"action");
alias NamedTrade = Tuple!(string,"symbol",DateTime,"time",double,"price",Action,"action");
auto completedOnly(Range) (Range trades) {
    auto rvalue = trades.filter!(a => a.action != Action.none)
                        .uniq!((a,b) => a.action == b.action)
                        .array;

    if (rvalue.empty) return rvalue;
    if (rvalue.front.action==Action.sell) {
        rvalue.popFront;
    }

    if (rvalue.back.action==Action.buy) {
        rvalue.popBack;
    }

    assert (rvalue.count % 2 == 0);
    return rvalue;
}

auto tradeAction(T) (T data, string ignore="No") { // TODO investigate adding no trade to start
    assert (data.count % 2 == 0);
    auto midpoint = data.count / 2;
    auto firstHalf = data.take(midpoint);
    auto lastHalf = data.drop(midpoint);


    // test buy
    if (firstHalf.all!(a => a[2] > a[0]-a[1]) &&
        lastHalf.all!(a => a[2] <= a[0]-a[1])) {

        if (ignore=="Yes") {
            if (firstHalf.front[0] > firstHalf.front[1]) return Action.buy;
        } else {
            return Action.buy;
        }
    }

    // test sell
    if (firstHalf.all!(a => a[2] < a[0]-a[1]) &&
        lastHalf.all!(a => a[2] >= a[0]-a[1])) {
        if (ignore=="Yes") {
            if (firstHalf.front[0] < firstHalf.front[1]) return Action.sell;
        } else {
            return Action.sell;
        }
    }

    return Action.none;
}

auto simulatedPrice (double price, double mu, double sigma, RecordSeriesType type=RecordSeriesType.daily) {
    import dstats : rNormal;
    import std.math : exp, pow, sqrt;
 
    auto numPeriods = (type==RecordSeriesType.daily) ? AnnualTradingDays : 12;

    return price*exp ((mu - (pow(sigma,2)/2))*(1/numPeriods.to!double) + (sigma/sqrt(numPeriods.to!double))*rNormal(0,1));
}


//auto macdSignals(Range) (Range rng) {
//    struct MacdSignals(T) {
//        T rng;
//        auto action = Action.none;
//
//        this (T r) {
//            rng = r;
//        }
//
//        auto front() {
//            if ([rng.front[0],rng.front[1],rng.front[2]].canFind!(a => a.isNaN)) {
//                return Action.none;
//            } else {
//                return action;
//            }
//        }
//
//        auto empty() {
//            return rng.empty;
//        }
//
//        auto popFront() {
//            auto oldPoint = rng.front;
//            rng.popFront;
//            if (!rng.empty) {
//                auto newPoint = rng.front;
//                if (oldPoint[2] <= (oldPoint[0]-oldPoint[1]) &&
//                    newPoint[2] > (newPoint[0] - newPoint[1])) {
//                    action = Action.buy;
//                } else if (oldPoint[2] >= (oldPoint[0]-oldPoint[1]) &&
//                           newPoint[2] < (newPoint[0] - newPoint[1])) {
//                    action = Action.sell;
//                } else {
//                    action = Action.none;
//                }
//            }
//        }
//    }
//    return MacdSignals!Range (rng);
//}

unittest {

}
