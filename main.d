module main;

import std.stdio;

import stocky;

import std.typecons : Tuple;
import std.array : appender;
import std.datetime.stopwatch;
import std.datetime;

import std.algorithm;
import std.range;
import std.conv : to;



void main(){

    stockyInit;
    Symbol("ASX","ANZ").macdStrat(200,100).each!(a => writeln(a[0],"\n",a[1],"\n",a[1].price-a[0].price,"\n"));
                       //.returns
                       //.writeln;

    //readln;
	return;
}
