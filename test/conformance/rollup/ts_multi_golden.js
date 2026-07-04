'use strict';

const upper = (s) => s.toUpperCase();
const PUNCT = "!";
var Unused; (function (Unused) { const A = 0; Unused[Unused["A"] = A] = "A"; const B = A + 1; Unused[Unused["B"] = B] = "B"; })(Unused || (Unused = {}));

function greet(n) { return "hi " + upper(n) + PUNCT; }
class Farewell { say(n) { return "bye " + n; } }

const VERSION = "@v1";

const who = { name: "world" };
const msg = greet(who.name) + " " + new Farewell().say(who.name) + VERSION;
console.log(msg);

exports.msg = msg;
