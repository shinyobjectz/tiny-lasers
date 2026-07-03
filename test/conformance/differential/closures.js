function counter(){ var n = 0; return function(){ return ++n; }; }
var c = counter();
print("" + c() + c() + c());
function memoize(fn){ var cache = {}; return function(x){ if (cache[x] === undefined) cache[x] = fn(x); return cache[x]; }; }
var calls = 0;
var square = memoize(function(x){ calls++; return x * x; });
print("" + square(4) + "," + square(4) + "," + square(5) + " calls=" + calls);
function adder(a){ return function(b){ return function(c){ return a + b + c; }; }; }
print("" + adder(1)(2)(3));
