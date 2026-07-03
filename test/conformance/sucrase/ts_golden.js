
var L; (function (L) { const A = 1; L[L["A"] = A] = "A"; const B = 4; L[L["B"] = B] = "B"; })(L || (L = {}));
const g = (u, l = L.A) => `${u.name}:${l}`;
class R {constructor() { R.prototype.__init.call(this); }  __init() {this.xs = []} add(x) { this.xs.push(x); return this; } get n() { return this.xs.length; } }
const r = new R(); r.add({ name: 'ada' } );
let out = g({ name: 'ada' }, L.B) + '|' + r.n;

