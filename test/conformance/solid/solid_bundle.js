(() => {
  // node_modules/solid-js/dist/server.js
  var ERROR = /* @__PURE__ */ Symbol("error");
  function castError(err) {
    if (err instanceof Error) return err;
    return new Error(typeof err === "string" ? err : "Unknown error", {
      cause: err
    });
  }
  function handleError(err, owner = Owner) {
    const fns = owner && owner.context && owner.context[ERROR];
    const error = castError(err);
    if (!fns) throw error;
    try {
      for (const f3 of fns) f3(error);
    } catch (e) {
      handleError(e, owner && owner.owner || null);
    }
  }
  var UNOWNED = {
    context: null,
    owner: null,
    owned: null,
    cleanups: null
  };
  var Owner = null;
  function createOwner() {
    const o3 = {
      owner: Owner,
      context: Owner ? Owner.context : null,
      owned: null,
      cleanups: null
    };
    if (Owner) {
      if (!Owner.owned) Owner.owned = [o3];
      else Owner.owned.push(o3);
    }
    return o3;
  }
  function createRoot(fn2, detachedOwner) {
    const owner = Owner, current = detachedOwner === void 0 ? owner : detachedOwner, root = fn2.length === 0 ? UNOWNED : {
      context: current ? current.context : null,
      owner: current,
      owned: null,
      cleanups: null
    };
    Owner = root;
    let result;
    try {
      result = fn2(fn2.length === 0 ? () => {
      } : () => cleanNode(root));
    } catch (err) {
      handleError(err);
    } finally {
      Owner = owner;
    }
    return result;
  }
  function createSignal(value, options) {
    return [() => value, (v3) => {
      return value = typeof v3 === "function" ? v3(value) : v3;
    }];
  }
  function createMemo(fn2, value) {
    Owner = createOwner();
    let v3;
    try {
      v3 = fn2(value);
    } catch (err) {
      handleError(err);
    } finally {
      Owner = Owner.owner;
    }
    return () => v3;
  }
  function cleanNode(node) {
    if (node.owned) {
      for (let i2 = 0; i2 < node.owned.length; i2++) cleanNode(node.owned[i2]);
      node.owned = null;
    }
    if (node.cleanups) {
      for (let i2 = 0; i2 < node.cleanups.length; i2++) node.cleanups[i2]();
      node.cleanups = null;
    }
  }
  function createContext(defaultValue) {
    const id = /* @__PURE__ */ Symbol("context");
    return {
      id,
      Provider: createProvider(id),
      defaultValue
    };
  }
  function children(fn2) {
    const memo = createMemo(() => resolveChildren(fn2()));
    memo.toArray = () => {
      const c3 = memo();
      return Array.isArray(c3) ? c3 : c3 != null ? [c3] : [];
    };
    return memo;
  }
  function resolveChildren(children2) {
    if (typeof children2 === "function" && !children2.length) return resolveChildren(children2());
    if (Array.isArray(children2)) {
      const results = [];
      for (let i2 = 0; i2 < children2.length; i2++) {
        const result = resolveChildren(children2[i2]);
        if (Array.isArray(result)) {
          if (result.length < 32768) results.push.apply(results, result);
          else for (let j2 = 0; j2 < result.length; j2++) results.push(result[j2]);
        } else {
          results.push(result);
        }
      }
      return results;
    }
    return children2;
  }
  function createProvider(id) {
    return function provider(props) {
      return createMemo(() => {
        Owner.context = {
          ...Owner.context,
          [id]: props.value
        };
        return children(() => props.children);
      });
    };
  }
  var sharedConfig = {
    context: void 0,
    getContextId() {
      if (!this.context) throw new Error(`getContextId cannot be used under non-hydrating context`);
      return getContextId(this.context.count);
    },
    getNextContextId() {
      if (!this.context) throw new Error(`getNextContextId cannot be used under non-hydrating context`);
      return getContextId(this.context.count++);
    }
  };
  function getContextId(count) {
    const num = String(count), len = num.length - 1;
    return sharedConfig.context.id + (len ? String.fromCharCode(96 + len) : "") + num;
  }
  function setHydrateContext(context) {
    sharedConfig.context = context;
  }
  function nextHydrateContext() {
    return sharedConfig.context ? {
      ...sharedConfig.context,
      id: sharedConfig.getNextContextId(),
      count: 0
    } : void 0;
  }
  function createComponent(Comp, props) {
    if (sharedConfig.context && !sharedConfig.context.noHydrate) {
      const c3 = sharedConfig.context;
      setHydrateContext(nextHydrateContext());
      const r = Comp(props || {});
      setHydrateContext(c3);
      return r;
    }
    return Comp(props || {});
  }
  function simpleMap(props, wrap) {
    const list = props.each || [], len = list.length, fn2 = props.children;
    if (len) {
      let mapped = Array(len);
      for (let i2 = 0; i2 < len; i2++) mapped[i2] = wrap(fn2, list[i2], i2);
      return mapped;
    }
    return props.fallback;
  }
  function For(props) {
    return simpleMap(props, (fn2, item, i2) => fn2(item, () => i2));
  }
  function Show(props) {
    let c3;
    return props.when ? typeof (c3 = props.children) === "function" && c3.length > 0 ? c3(props.keyed ? props.when : () => props.when) : c3 : props.fallback || "";
  }
  var SuspenseContext = createContext();

  // node_modules/seroval/dist/esm/production/index.mjs
  var M = ((i2) => (i2[i2.AggregateError = 1] = "AggregateError", i2[i2.ArrowFunction = 2] = "ArrowFunction", i2[i2.ErrorPrototypeStack = 4] = "ErrorPrototypeStack", i2[i2.ObjectAssign = 8] = "ObjectAssign", i2[i2.BigIntTypedArray = 16] = "BigIntTypedArray", i2[i2.RegExp = 32] = "RegExp", i2))(M || {});
  var v = Symbol.asyncIterator;
  var pr = Symbol.hasInstance;
  var R = Symbol.isConcatSpreadable;
  var C = Symbol.iterator;
  var dr = Symbol.match;
  var gr = Symbol.matchAll;
  var yr = Symbol.replace;
  var Nr = Symbol.search;
  var br = Symbol.species;
  var vr = Symbol.split;
  var Cr = Symbol.toPrimitive;
  var P = Symbol.toStringTag;
  var Ar = Symbol.unscopables;
  var tt = { 0: "Symbol.asyncIterator", 1: "Symbol.hasInstance", 2: "Symbol.isConcatSpreadable", 3: "Symbol.iterator", 4: "Symbol.match", 5: "Symbol.matchAll", 6: "Symbol.replace", 7: "Symbol.search", 8: "Symbol.species", 9: "Symbol.split", 10: "Symbol.toPrimitive", 11: "Symbol.toStringTag", 12: "Symbol.unscopables" };
  var ve = { [v]: 0, [pr]: 1, [R]: 2, [C]: 3, [dr]: 4, [gr]: 5, [yr]: 6, [Nr]: 7, [br]: 8, [vr]: 9, [Cr]: 10, [P]: 11, [Ar]: 12 };
  var ot = { 2: "!0", 3: "!1", 1: "void 0", 0: "null", 4: "-0", 5: "1/0", 6: "-1/0", 7: "0/0" };
  var o = void 0;
  var at = { 2: true, 3: false, 1: o, 0: null, 4: -0, 5: Number.POSITIVE_INFINITY, 6: Number.NEGATIVE_INFINITY, 7: Number.NaN };
  var Ce = { 0: "Error", 1: "EvalError", 2: "RangeError", 3: "ReferenceError", 4: "SyntaxError", 5: "TypeError", 6: "URIError" };
  function c(e, r, t, n2, a, s, i2, u2, l2, g2, S, d2) {
    return { t: e, i: r, s: t, c: n2, m: a, p: s, e: i2, a: u2, f: l2, b: g2, o: S, l: d2 };
  }
  function B(e) {
    return c(2, o, e, o, o, o, o, o, o, o, o, o);
  }
  var H = B(2);
  var J = B(3);
  var Ae = B(1);
  var Ee = B(0);
  var it = B(4);
  var ut = B(5);
  var lt = B(6);
  var ct = B(7);
  function mn(e) {
    switch (e) {
      case '"':
        return '\\"';
      case "\\":
        return "\\\\";
      case `
`:
        return "\\n";
      case "\r":
        return "\\r";
      case "\b":
        return "\\b";
      case "	":
        return "\\t";
      case "\f":
        return "\\f";
      case "<":
        return "\\x3C";
      case "\u2028":
        return "\\u2028";
      case "\u2029":
        return "\\u2029";
      default:
        return o;
    }
  }
  function y(e) {
    let r = "", t = 0, n2;
    for (let a = 0, s = e.length; a < s; a++) n2 = mn(e[a]), n2 && (r += e.slice(t, a) + n2, t = a + 1);
    return t === 0 ? r = e : r += e.slice(t), r;
  }
  var L = "__SEROVAL_REFS__";
  var le = "$R";
  var Ie = `self.${le}`;
  function dn(e) {
    return e == null ? `${Ie}=${Ie}||[]` : `(${Ie}=${Ie}||{})["${y(e)}"]=[]`;
  }
  var Er = /* @__PURE__ */ new Map();
  var U = /* @__PURE__ */ new Map();
  function Ir(e) {
    return Er.has(e);
  }
  function ft(e) {
    if (Ir(e)) return Er.get(e);
    throw new Re(e);
  }
  typeof globalThis != "undefined" ? Object.defineProperty(globalThis, L, { value: U, configurable: true, writable: false, enumerable: false }) : typeof window != "undefined" ? Object.defineProperty(window, L, { value: U, configurable: true, writable: false, enumerable: false }) : typeof self != "undefined" ? Object.defineProperty(self, L, { value: U, configurable: true, writable: false, enumerable: false }) : typeof global != "undefined" && Object.defineProperty(global, L, { value: U, configurable: true, writable: false, enumerable: false });
  function xe(e) {
    return e instanceof EvalError ? 1 : e instanceof RangeError ? 2 : e instanceof ReferenceError ? 3 : e instanceof SyntaxError ? 4 : e instanceof TypeError ? 5 : e instanceof URIError ? 6 : 0;
  }
  function Nn(e) {
    let r = Ce[xe(e)];
    return e.name !== r ? { name: e.name } : e.constructor.name !== r ? { name: e.constructor.name } : {};
  }
  function Z(e, r) {
    let t = Nn(e), n2 = Object.getOwnPropertyNames(e);
    for (let a = 0, s = n2.length, i2; a < s; a++) i2 = n2[a], i2 !== "name" && i2 !== "message" && (i2 === "stack" ? r & 4 && (t = t || {}, t[i2] = e[i2]) : (t = t || {}, t[i2] = e[i2]));
    return t;
  }
  function Te(e) {
    return Object.isFrozen(e) ? 3 : Object.isSealed(e) ? 2 : Object.isExtensible(e) ? 0 : 1;
  }
  function Oe(e) {
    switch (e) {
      case Number.POSITIVE_INFINITY:
        return ut;
      case Number.NEGATIVE_INFINITY:
        return lt;
    }
    return e !== e ? ct : Object.is(e, -0) ? it : c(0, o, e, o, o, o, o, o, o, o, o, o);
  }
  function $(e) {
    return c(1, o, y(e), o, o, o, o, o, o, o, o, o);
  }
  function we(e) {
    return c(3, o, "" + e, o, o, o, o, o, o, o, o, o);
  }
  function pt(e) {
    return c(4, e, o, o, o, o, o, o, o, o, o, o);
  }
  function he(e, r) {
    let t = r.valueOf();
    return c(5, e, t !== t ? "" : r.toISOString(), o, o, o, o, o, o, o, o, o);
  }
  function ze(e, r) {
    return c(6, e, o, y(r.source), r.flags, o, o, o, o, o, o, o);
  }
  function dt(e, r) {
    return c(17, e, ve[r], o, o, o, o, o, o, o, o, o);
  }
  function gt(e, r) {
    return c(18, e, y(ft(r)), o, o, o, o, o, o, o, o, o);
  }
  function ce(e, r, t) {
    return c(25, e, t, y(r), o, o, o, o, o, o, o, o);
  }
  function _e(e, r, t) {
    return c(9, e, o, o, o, o, o, t, o, o, Te(r), o);
  }
  function ke(e, r) {
    return c(21, e, o, o, o, o, o, o, r, o, o, o);
  }
  function De(e, r, t) {
    return c(15, e, o, r.constructor.name, o, o, o, o, t, r.byteOffset, o, r.length);
  }
  function Fe(e, r, t) {
    return c(16, e, o, r.constructor.name, o, o, o, o, t, r.byteOffset, o, r.byteLength);
  }
  function Be(e, r, t) {
    return c(20, e, o, o, o, o, o, o, t, r.byteOffset, o, r.byteLength);
  }
  function Ve(e, r, t) {
    return c(13, e, xe(r), o, y(r.message), t, o, o, o, o, o, o);
  }
  function Me(e, r, t) {
    return c(14, e, xe(r), o, y(r.message), t, o, o, o, o, o, o);
  }
  function Le(e, r) {
    return c(7, e, o, o, o, o, o, r, o, o, o, o);
  }
  function Ue(e, r) {
    return c(28, o, o, o, o, o, o, [e, r], o, o, o, o);
  }
  function je(e, r) {
    return c(30, o, o, o, o, o, o, [e, r], o, o, o, o);
  }
  function Ye(e, r, t) {
    return c(31, e, o, o, o, o, o, t, r, o, o, o);
  }
  function qe(e, r) {
    return c(32, e, o, o, o, o, o, o, r, o, o, o);
  }
  function We(e, r) {
    return c(33, e, o, o, o, o, o, o, r, o, o, o);
  }
  function Ge(e, r) {
    return c(34, e, o, o, o, o, o, o, r, o, o, o);
  }
  function Ke(e, r, t, n2) {
    return c(35, e, t, o, o, o, o, r, o, o, o, n2);
  }
  var { toString: bs } = Object.prototype;
  var bn = { parsing: 1, serialization: 2, deserialization: 3 };
  function vn(e) {
    return `Seroval Error (step: ${bn[e]})`;
  }
  var Cn = (e, r) => vn(e);
  var fe = class extends Error {
    constructor(t, n2) {
      super(Cn(t, n2));
      this.cause = n2;
    }
  };
  var z = class extends fe {
    constructor(r) {
      super("parsing", r);
    }
  };
  function _(e) {
    return `Seroval Error (specific: ${e})`;
  }
  var x = class extends Error {
    constructor(t) {
      super(_(1));
      this.value = t;
    }
  };
  var h = class extends Error {
    constructor(r) {
      super(_(2));
    }
  };
  var X = class extends Error {
    constructor(r) {
      super(_(3));
    }
  };
  var Re = class extends Error {
    constructor(t) {
      super(_(5));
      this.value = t;
    }
  };
  var Q = class extends Error {
    constructor(r) {
      super(_(9));
    }
  };
  var j = class {
    constructor(r, t) {
      this.value = r;
      this.replacement = t;
    }
  };
  var ee = () => {
    let e = { p: 0, s: 0, f: 0 };
    return e.p = new Promise((r, t) => {
      e.s = r, e.f = t;
    }), e;
  };
  var An = (e, r) => {
    e.s(r), e.p.s = 1, e.p.v = r;
  };
  var En = (e, r) => {
    e.f(r), e.p.s = 2, e.p.v = r;
  };
  var Nt = ee.toString();
  var bt = An.toString();
  var vt = En.toString();
  var Pr = () => {
    let e = [], r = [], t = true, n2 = false, a = 0, s = (l2, g2, S) => {
      for (S = 0; S < a; S++) r[S] && r[S][g2](l2);
    }, i2 = (l2, g2, S, d2) => {
      for (g2 = 0, S = e.length; g2 < S; g2++) d2 = e[g2], !t && g2 === S - 1 ? l2[n2 ? "return" : "throw"](d2) : l2.next(d2);
    }, u2 = (l2, g2) => (t && (g2 = a++, r[g2] = l2), i2(l2), () => {
      t && (r[g2] = r[a], r[a--] = void 0);
    });
    return { __SEROVAL_STREAM__: true, on: (l2) => u2(l2), next: (l2) => {
      t && (e.push(l2), s(l2, "next"));
    }, throw: (l2) => {
      t && (e.push(l2), s(l2, "throw"), t = false, n2 = false, r.length = 0);
    }, return: (l2) => {
      t && (e.push(l2), s(l2, "return"), t = false, n2 = true, r.length = 0);
    } };
  };
  var Ct = Pr.toString();
  var xr = (e) => (r) => () => {
    let t = 0, n2 = { [e]: () => n2, next: () => {
      if (t > r.d) return { done: true, value: void 0 };
      let a = t++, s = r.v[a];
      if (a === r.t) throw s;
      return { done: a === r.d, value: s };
    } };
    return n2;
  };
  var At = xr.toString();
  var Tr = (e, r) => (t) => () => {
    let n2 = 0, a = -1, s = false, i2 = [], u2 = [], l2 = (S = 0, d2 = u2.length) => {
      for (; S < d2; S++) u2[S].s({ done: true, value: void 0 });
    };
    t.on({ next: (S) => {
      let d2 = u2.shift();
      d2 && d2.s({ done: false, value: S }), i2.push(S);
    }, throw: (S) => {
      let d2 = u2.shift();
      d2 && d2.f(S), l2(), a = i2.length, s = true, i2.push(S);
    }, return: (S) => {
      let d2 = u2.shift();
      d2 && d2.s({ done: true, value: S }), l2(), a = i2.length, i2.push(S);
    } });
    let g2 = { [e]: () => g2, next: () => {
      if (a === -1) {
        let G2 = n2++;
        if (G2 >= i2.length) {
          let rt = r();
          return u2.push(rt), rt.p;
        }
        return { done: false, value: i2[G2] };
      }
      if (n2 > a) return { done: true, value: void 0 };
      let S = n2++, d2 = i2[S];
      if (S !== a) return { done: false, value: d2 };
      if (s) throw d2;
      return { done: true, value: d2 };
    } };
    return g2;
  };
  var Et = Tr.toString();
  var Or = (e) => {
    let r = atob(e), t = r.length, n2 = new Uint8Array(t);
    for (let a = 0; a < t; a++) n2[a] = r.charCodeAt(a);
    return n2.buffer;
  };
  var It = Or.toString();
  function Ze(e) {
    return "__SEROVAL_SEQUENCE__" in e;
  }
  function wr(e, r, t) {
    return { __SEROVAL_SEQUENCE__: true, v: e, t: r, d: t };
  }
  function $e(e) {
    let r = [], t = -1, n2 = -1, a = e[C]();
    for (; ; ) try {
      let s = a.next();
      if (r.push(s.value), s.done) {
        n2 = r.length - 1;
        break;
      }
    } catch (s) {
      t = r.length, r.push(s);
    }
    return wr(r, t, n2);
  }
  var In = xr(C);
  var Pt = {};
  var xt = {};
  var Tt = { 0: {}, 1: {}, 2: {}, 3: {}, 4: {}, 5: {} };
  var Ot = { 0: "[]", 1: Nt, 2: bt, 3: vt, 4: Ct, 5: It };
  function Xe(e) {
    return "__SEROVAL_STREAM__" in e;
  }
  function re() {
    return Pr();
  }
  function Qe(e) {
    let r = re(), t = e[v]();
    async function n2() {
      try {
        let a = await t.next();
        a.done ? r.return(a.value) : (r.next(a.value), await n2());
      } catch (a) {
        r.throw(a);
      }
    }
    return n2().catch(() => {
    }), r;
  }
  var Rn = Tr(v, ee);
  function me(e, r) {
    return { plugins: r.plugins, mode: e, marked: /* @__PURE__ */ new Set(), features: 63 ^ (r.disabledFeatures || 0), refs: r.refs || /* @__PURE__ */ new Map(), depthLimit: r.depthLimit || 1e3 };
  }
  function pe(e, r) {
    e.marked.add(r);
  }
  function zr(e, r) {
    let t = e.refs.size;
    return e.refs.set(r, t), t;
  }
  function er(e, r) {
    let t = e.refs.get(r);
    return t != null ? (pe(e, t), { type: 1, value: pt(t) }) : { type: 0, value: zr(e, r) };
  }
  function Y(e, r) {
    let t = er(e, r);
    return t.type === 1 ? t : Ir(r) ? { type: 2, value: gt(t.value, r) } : t;
  }
  function I(e, r) {
    let t = Y(e, r);
    if (t.type !== 0) return t.value;
    if (r in ve) return dt(t.value, r);
    throw new x(r);
  }
  function k(e, r) {
    let t = er(e, Tt[r]);
    return t.type === 1 ? t.value : c(26, t.value, r, o, o, o, o, o, o, o, o, o);
  }
  function rr(e) {
    let r = er(e, Pt);
    return r.type === 1 ? r.value : c(27, r.value, o, o, o, o, o, o, I(e, C), o, o, o);
  }
  function tr(e) {
    let r = er(e, xt);
    return r.type === 1 ? r.value : c(29, r.value, o, o, o, o, o, [k(e, 1), I(e, v)], o, o, o, o);
  }
  function nr(e, r, t, n2) {
    return c(t ? 11 : 10, e, o, o, o, n2, o, o, o, o, Te(r), o);
  }
  function or(e, r, t, n2) {
    return c(8, r, o, o, o, o, { k: t, v: n2 }, o, k(e, 0), o, o, o);
  }
  function zt(e, r, t) {
    return c(22, r, t, o, o, o, o, o, k(e, 1), o, o, o);
  }
  function ar(e, r, t) {
    let n2 = new Uint8Array(t), a = "";
    for (let s = 0, i2 = n2.length; s < i2; s++) a += String.fromCharCode(n2[s]);
    return c(19, r, y(btoa(a)), o, o, o, o, o, k(e, 5), o, o, o);
  }
  var oe = ((t) => (t[t.Vanilla = 1] = "Vanilla", t[t.Cross = 2] = "Cross", t))(oe || {});
  function ai(e) {
    return e;
  }
  function Dt(e, r) {
    for (let t = 0, n2 = r.length; t < n2; t++) {
      let a = r[t];
      e.has(a) || (e.add(a), a.extends && Dt(e, a.extends));
    }
  }
  function A(e) {
    if (e) {
      let r = /* @__PURE__ */ new Set();
      return Dt(r, e), [...r];
    }
  }
  var Ro = () => T;
  var Po = Ro.toString();
  var Gt = /=>/.test(Po);
  function ir(e, r) {
    return Gt ? (e.length === 1 ? e[0] : "(" + e.join(",") + ")") + "=>" + (r.startsWith("{") ? "(" + r + ")" : r) : "function(" + e.join(",") + "){return " + r + "}";
  }
  function Kt(e, r) {
    return Gt ? (e.length === 1 ? e[0] : "(" + e.join(",") + ")") + "=>{" + r + "}" : "function(" + e.join(",") + "){" + r + "}";
  }
  var Zt = "hjkmoquxzABCDEFGHIJKLNPQRTUVWXYZ$_";
  var Ht = Zt.length;
  var $t = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789$_";
  var Jt = $t.length;
  function Vr(e) {
    let r = e % Ht, t = Zt[r];
    for (e = (e - r) / Ht; e > 0; ) r = e % Jt, t += $t[r], e = (e - r) / Jt;
    return t;
  }
  var xo = /^[$A-Z_][0-9A-Z_$]*$/i;
  function Mr(e) {
    let r = e[0];
    return (r === "$" || r === "_" || r >= "A" && r <= "Z" || r >= "a" && r <= "z") && xo.test(e);
  }
  function ye(e) {
    switch (e.t) {
      case 0:
        return e.s + "=" + e.v;
      case 2:
        return e.s + ".set(" + e.k + "," + e.v + ")";
      case 1:
        return e.s + ".add(" + e.v + ")";
      case 3:
        return e.s + ".delete(" + e.k + ")";
    }
  }
  function To(e) {
    let r = [], t = e[0];
    for (let n2 = 1, a = e.length, s, i2 = t; n2 < a; n2++) s = e[n2], s.t === 0 && s.v === i2.v ? t = { t: 0, s: s.s, k: o, v: ye(t) } : s.t === 2 && s.s === i2.s ? t = { t: 2, s: ye(t), k: s.k, v: s.v } : s.t === 1 && s.s === i2.s ? t = { t: 1, s: ye(t), k: o, v: s.v } : s.t === 3 && s.s === i2.s ? t = { t: 3, s: ye(t), k: s.k, v: o } : (r.push(t), t = s), i2 = s;
    return r.push(t), r;
  }
  function on(e) {
    if (e.length) {
      let r = "", t = To(e);
      for (let n2 = 0, a = t.length; n2 < a; n2++) r += ye(t[n2]) + ",";
      return r;
    }
    return o;
  }
  var Oo = "Object.create(null)";
  var wo = "new Set";
  var ho = "new Map";
  var zo = "Promise.resolve";
  var _o = "Promise.reject";
  var ko = { 3: "Object.freeze", 2: "Object.seal", 1: "Object.preventExtensions", 0: o };
  function an(e, r) {
    return { mode: e, plugins: r.plugins, features: r.features, marked: new Set(r.markedRefs), stack: [], flags: [], assignments: [] };
  }
  function lr(e) {
    return { mode: 2, base: an(2, e), state: e, child: o };
  }
  var Lr = class {
    constructor(r) {
      this._p = r;
    }
    serialize(r) {
      return f(this._p, r);
    }
  };
  function Fo(e, r) {
    let t = e.valid.get(r);
    t == null && (t = e.valid.size, e.valid.set(r, t));
    let n2 = e.vars[t];
    return n2 == null && (n2 = Vr(t), e.vars[t] = n2), n2;
  }
  function Bo(e) {
    return le + "[" + e + "]";
  }
  function m(e, r) {
    return e.mode === 1 ? Fo(e.state, r) : Bo(r);
  }
  function w(e, r) {
    e.marked.add(r);
  }
  function Ur(e, r) {
    return e.marked.has(r);
  }
  function Yr(e, r, t) {
    r !== 0 && (w(e.base, t), e.base.flags.push({ type: r, value: m(e, t) }));
  }
  function Vo(e) {
    let r = "";
    for (let t = 0, n2 = e.flags, a = n2.length; t < a; t++) {
      let s = n2[t];
      r += ko[s.type] + "(" + s.value + "),";
    }
    return r;
  }
  function sn(e) {
    let r = on(e.assignments), t = Vo(e);
    return r ? t ? r + t : r : t;
  }
  function qr(e, r, t) {
    e.assignments.push({ t: 0, s: r, k: o, v: t });
  }
  function Mo(e, r, t) {
    e.base.assignments.push({ t: 1, s: m(e, r), k: o, v: t });
  }
  function ge(e, r, t, n2) {
    e.base.assignments.push({ t: 2, s: m(e, r), k: t, v: n2 });
  }
  function Xt(e, r, t) {
    e.base.assignments.push({ t: 3, s: m(e, r), k: t, v: o });
  }
  function Ne(e, r, t, n2) {
    qr(e.base, m(e, r) + "[" + t + "]", n2);
  }
  function jr(e, r, t, n2) {
    qr(e.base, m(e, r) + "." + t, n2);
  }
  function Lo(e, r, t, n2) {
    qr(e.base, m(e, r) + ".v[" + t + "]", n2);
  }
  function F(e, r) {
    return r.t === 4 && e.stack.includes(r.i);
  }
  function ae(e, r, t) {
    return e.mode === 1 && !Ur(e.base, r) ? t : m(e, r) + "=" + t;
  }
  function Uo(e) {
    return L + '.get("' + e.s + '")';
  }
  function Qt(e, r, t, n2) {
    return t ? F(e.base, t) ? (w(e.base, r), Ne(e, r, n2, m(e, t.i)), "") : f(e, t) : "";
  }
  function jo(e, r) {
    let t = r.i, n2 = r.a, a = n2.length;
    if (a > 0) {
      e.base.stack.push(t);
      let s = Qt(e, t, n2[0], 0), i2 = s === "";
      for (let u2 = 1, l2; u2 < a; u2++) l2 = Qt(e, t, n2[u2], u2), s += "," + l2, i2 = l2 === "";
      return e.base.stack.pop(), Yr(e, r.o, r.i), "[" + s + (i2 ? ",]" : "]");
    }
    return "[]";
  }
  function en(e, r, t, n2) {
    if (typeof t == "string") {
      let a = Number(t), s = a >= 0 && a.toString() === t || Mr(t);
      if (F(e.base, n2)) {
        let i2 = m(e, n2.i);
        return w(e.base, r.i), s && a !== a ? jr(e, r.i, t, i2) : Ne(e, r.i, s ? t : '"' + t + '"', i2), "";
      }
      return (s ? t : '"' + t + '"') + ":" + f(e, n2);
    }
    return "[" + f(e, t) + "]:" + f(e, n2);
  }
  function un(e, r, t) {
    let n2 = t.k, a = n2.length;
    if (a > 0) {
      let s = t.v;
      e.base.stack.push(r.i);
      let i2 = en(e, r, n2[0], s[0]);
      for (let u2 = 1, l2 = i2; u2 < a; u2++) l2 = en(e, r, n2[u2], s[u2]), i2 += (l2 && i2 && ",") + l2;
      return e.base.stack.pop(), "{" + i2 + "}";
    }
    return "{}";
  }
  function Yo(e, r) {
    return Yr(e, r.o, r.i), un(e, r, r.p);
  }
  function qo(e, r, t, n2) {
    let a = un(e, r, t);
    return a !== "{}" ? "Object.assign(" + n2 + "," + a + ")" : n2;
  }
  function Wo(e, r, t, n2, a) {
    let s = e.base, i2 = f(e, a), u2 = Number(n2), l2 = u2 >= 0 && u2.toString() === n2 || Mr(n2);
    if (F(s, a)) l2 && u2 !== u2 ? jr(e, r.i, n2, i2) : Ne(e, r.i, l2 ? n2 : '"' + n2 + '"', i2);
    else {
      let g2 = s.assignments;
      s.assignments = t, l2 && u2 !== u2 ? jr(e, r.i, n2, i2) : Ne(e, r.i, l2 ? n2 : '"' + n2 + '"', i2), s.assignments = g2;
    }
  }
  function Go(e, r, t, n2, a) {
    if (typeof n2 == "string") Wo(e, r, t, n2, a);
    else {
      let s = e.base, i2 = s.stack;
      s.stack = [];
      let u2 = f(e, a);
      s.stack = i2;
      let l2 = s.assignments;
      s.assignments = t, Ne(e, r.i, f(e, n2), u2), s.assignments = l2;
    }
  }
  function Ko(e, r, t) {
    let n2 = t.k, a = n2.length;
    if (a > 0) {
      let s = [], i2 = t.v;
      e.base.stack.push(r.i);
      for (let u2 = 0; u2 < a; u2++) Go(e, r, s, n2[u2], i2[u2]);
      return e.base.stack.pop(), on(s);
    }
    return o;
  }
  function Wr(e, r, t) {
    if (r.p) {
      let n2 = e.base;
      if (n2.features & 8) t = qo(e, r, r.p, t);
      else {
        w(n2, r.i);
        let a = Ko(e, r, r.p);
        if (a) return "(" + ae(e, r.i, t) + "," + a + m(e, r.i) + ")";
      }
    }
    return t;
  }
  function Ho(e, r) {
    return Yr(e, r.o, r.i), Wr(e, r, Oo);
  }
  function Jo(e) {
    return 'new Date("' + e.s + '")';
  }
  function Zo(e, r) {
    if (e.base.features & 32) return "/" + r.c + "/" + r.m;
    throw new h(r);
  }
  function rn(e, r, t) {
    let n2 = e.base;
    return F(n2, t) ? (w(n2, r), Mo(e, r, m(e, t.i)), "") : f(e, t);
  }
  function $o(e, r) {
    let t = wo, n2 = r.a, a = n2.length, s = r.i;
    if (a > 0) {
      e.base.stack.push(s);
      let i2 = rn(e, s, n2[0]);
      for (let u2 = 1, l2 = i2; u2 < a; u2++) l2 = rn(e, s, n2[u2]), i2 += (l2 && i2 && ",") + l2;
      e.base.stack.pop(), i2 && (t += "([" + i2 + "])");
    }
    return t;
  }
  function tn(e, r, t, n2, a) {
    let s = e.base;
    if (F(s, t)) {
      let i2 = m(e, t.i);
      if (w(s, r), F(s, n2)) {
        let l2 = m(e, n2.i);
        return ge(e, r, i2, l2), "";
      }
      if (n2.t !== 4 && n2.i != null && Ur(s, n2.i)) {
        let l2 = "(" + f(e, n2) + ",[" + a + "," + a + "])";
        return ge(e, r, i2, m(e, n2.i)), Xt(e, r, a), l2;
      }
      let u2 = s.stack;
      return s.stack = [], ge(e, r, i2, f(e, n2)), s.stack = u2, "";
    }
    if (F(s, n2)) {
      let i2 = m(e, n2.i);
      if (w(s, r), t.t !== 4 && t.i != null && Ur(s, t.i)) {
        let l2 = "(" + f(e, t) + ",[" + a + "," + a + "])";
        return ge(e, r, m(e, t.i), i2), Xt(e, r, a), l2;
      }
      let u2 = s.stack;
      return s.stack = [], ge(e, r, f(e, t), i2), s.stack = u2, "";
    }
    return "[" + f(e, t) + "," + f(e, n2) + "]";
  }
  function Xo(e, r) {
    let t = ho, n2 = r.e.k, a = n2.length, s = r.i, i2 = r.f, u2 = m(e, i2.i), l2 = e.base;
    if (a > 0) {
      let g2 = r.e.v;
      l2.stack.push(s);
      let S = tn(e, s, n2[0], g2[0], u2);
      for (let d2 = 1, G2 = S; d2 < a; d2++) G2 = tn(e, s, n2[d2], g2[d2], u2), S += (G2 && S && ",") + G2;
      l2.stack.pop(), S && (t += "([" + S + "])");
    }
    return i2.t === 26 && (w(l2, i2.i), t = "(" + f(e, i2) + "," + t + ")"), t;
  }
  function Qo(e, r) {
    return q(e, r.f) + '("' + r.s + '")';
  }
  function ea(e, r) {
    return "new " + r.c + "(" + f(e, r.f) + "," + r.b + "," + r.l + ")";
  }
  function ra(e, r) {
    return "new DataView(" + f(e, r.f) + "," + r.b + "," + r.l + ")";
  }
  function ta(e, r) {
    let t = r.i;
    e.base.stack.push(t);
    let n2 = Wr(e, r, 'new AggregateError([],"' + r.m + '")');
    return e.base.stack.pop(), n2;
  }
  function na(e, r) {
    return Wr(e, r, "new " + Ce[r.s] + '("' + r.m + '")');
  }
  function oa(e, r) {
    let t, n2 = r.f, a = r.i, s = r.s ? zo : _o, i2 = e.base;
    if (F(i2, n2)) {
      let u2 = m(e, n2.i);
      t = s + (r.s ? "().then(" + ir([], u2) + ")" : "().catch(" + Kt([], "throw " + u2) + ")");
    } else {
      i2.stack.push(a);
      let u2 = f(e, n2);
      i2.stack.pop(), t = s + "(" + u2 + ")";
    }
    return t;
  }
  function aa(e, r) {
    return "Object(" + f(e, r.f) + ")";
  }
  function q(e, r) {
    let t = f(e, r);
    return r.t === 4 ? t : "(" + t + ")";
  }
  function sa(e, r) {
    if (e.mode === 1) throw new h(r);
    return "(" + ae(e, r.s, q(e, r.f) + "()") + ").p";
  }
  function ia(e, r) {
    if (e.mode === 1) throw new h(r);
    return q(e, r.a[0]) + "(" + m(e, r.i) + "," + f(e, r.a[1]) + ")";
  }
  function ua(e, r) {
    if (e.mode === 1) throw new h(r);
    return q(e, r.a[0]) + "(" + m(e, r.i) + "," + f(e, r.a[1]) + ")";
  }
  function la(e, r) {
    let t = e.base.plugins;
    if (t) for (let n2 = 0, a = t.length; n2 < a; n2++) {
      let s = t[n2];
      if (s.tag === r.c) return e.child == null && (e.child = new Lr(e)), s.serialize(r.s, e.child, { id: r.i });
    }
    throw new X(r.c);
  }
  function ca(e, r) {
    let t = "", n2 = false;
    return r.f.t !== 4 && (w(e.base, r.f.i), t = "(" + f(e, r.f) + ",", n2 = true), t += ae(e, r.i, "(" + At + ")(" + m(e, r.f.i) + ")"), n2 && (t += ")"), t;
  }
  function fa(e, r) {
    return q(e, r.a[0]) + "(" + f(e, r.a[1]) + ")";
  }
  function Sa(e, r) {
    let t = r.a[0], n2 = r.a[1], a = e.base, s = "";
    t.t !== 4 && (w(a, t.i), s += "(" + f(e, t)), n2.t !== 4 && (w(a, n2.i), s += (s ? "," : "(") + f(e, n2)), s && (s += ",");
    let i2 = ae(e, r.i, "(" + Et + ")(" + m(e, n2.i) + "," + m(e, t.i) + ")");
    return s ? s + i2 + ")" : i2;
  }
  function ma(e, r) {
    return q(e, r.a[0]) + "(" + f(e, r.a[1]) + ")";
  }
  function pa(e, r) {
    let t = ae(e, r.i, q(e, r.f) + "()"), n2 = r.a.length;
    if (n2) {
      let a = f(e, r.a[0]);
      for (let s = 1; s < n2; s++) a += "," + f(e, r.a[s]);
      return "(" + t + "," + a + "," + m(e, r.i) + ")";
    }
    return t;
  }
  function da(e, r) {
    return m(e, r.i) + ".next(" + f(e, r.f) + ")";
  }
  function ga(e, r) {
    return m(e, r.i) + ".throw(" + f(e, r.f) + ")";
  }
  function ya(e, r) {
    return m(e, r.i) + ".return(" + f(e, r.f) + ")";
  }
  function nn(e, r, t, n2) {
    let a = e.base;
    return F(a, n2) ? (w(a, r), Lo(e, r, t, m(e, n2.i)), "") : f(e, n2);
  }
  function Na(e, r) {
    let t = r.a, n2 = t.length, a = r.i;
    if (n2 > 0) {
      e.base.stack.push(a);
      let s = nn(e, a, 0, t[0]);
      for (let i2 = 1, u2 = s; i2 < n2; i2++) u2 = nn(e, a, i2, t[i2]), s += (u2 && s && ",") + u2;
      if (e.base.stack.pop(), s) return "{__SEROVAL_SEQUENCE__:!0,v:[" + s + "],t:" + r.s + ",d:" + r.l + "}";
    }
    return "{__SEROVAL_SEQUENCE__:!0,v:[],t:-1,d:0}";
  }
  function ba(e, r) {
    switch (r.t) {
      case 17:
        return tt[r.s];
      case 18:
        return Uo(r);
      case 9:
        return jo(e, r);
      case 10:
        return Yo(e, r);
      case 11:
        return Ho(e, r);
      case 5:
        return Jo(r);
      case 6:
        return Zo(e, r);
      case 7:
        return $o(e, r);
      case 8:
        return Xo(e, r);
      case 19:
        return Qo(e, r);
      case 16:
      case 15:
        return ea(e, r);
      case 20:
        return ra(e, r);
      case 14:
        return ta(e, r);
      case 13:
        return na(e, r);
      case 12:
        return oa(e, r);
      case 21:
        return aa(e, r);
      case 22:
        return sa(e, r);
      case 25:
        return la(e, r);
      case 26:
        return Ot[r.s];
      case 35:
        return Na(e, r);
      default:
        throw new h(r);
    }
  }
  function f(e, r) {
    switch (r.t) {
      case 2:
        return ot[r.s];
      case 0:
        return "" + r.s;
      case 1:
        return '"' + r.s + '"';
      case 3:
        return r.s + "n";
      case 4:
        return m(e, r.i);
      case 23:
        return ia(e, r);
      case 24:
        return ua(e, r);
      case 27:
        return ca(e, r);
      case 28:
        return fa(e, r);
      case 29:
        return Sa(e, r);
      case 30:
        return ma(e, r);
      case 31:
        return pa(e, r);
      case 32:
        return da(e, r);
      case 33:
        return ga(e, r);
      case 34:
        return ya(e, r);
      default:
        return ae(e, r.i, ba(e, r));
    }
  }
  function fr(e, r) {
    let t = f(e, r), n2 = r.i;
    if (n2 == null) return t;
    let a = sn(e.base), s = m(e, n2), i2 = e.state.scopeId, u2 = i2 == null ? "" : le, l2 = a ? "(" + t + "," + a + s + ")" : t;
    if (u2 === "") return r.t === 10 && !a ? "(" + l2 + ")" : l2;
    let g2 = i2 == null ? "()" : "(" + le + '["' + y(i2) + '"])';
    return "(" + ir([u2], l2) + ")" + g2;
  }
  var Kr = class {
    constructor(r, t) {
      this._p = r;
      this.depth = t;
    }
    parse(r) {
      return E(this._p, this.depth, r);
    }
  };
  var Hr = class {
    constructor(r, t) {
      this._p = r;
      this.depth = t;
    }
    parse(r) {
      return E(this._p, this.depth, r);
    }
    parseWithError(r) {
      return W(this._p, this.depth, r);
    }
    isAlive() {
      return this._p.state.alive;
    }
    pushPendingState() {
      Qr(this._p);
    }
    popPendingState() {
      be(this._p);
    }
    onParse(r) {
      se(this._p, r);
    }
    onError(r) {
      $r(this._p, r);
    }
  };
  function va(e) {
    return { alive: true, pending: 0, initial: true, buffer: [], onParse: e.onParse, onError: e.onError, onDone: e.onDone };
  }
  function Jr(e) {
    return { type: 2, base: me(2, e), state: va(e) };
  }
  function Ca(e, r, t) {
    let n2 = [];
    for (let a = 0, s = t.length; a < s; a++) a in t ? n2[a] = E(e, r, t[a]) : n2[a] = 0;
    return n2;
  }
  function Aa(e, r, t, n2) {
    return _e(t, n2, Ca(e, r, n2));
  }
  function Zr(e, r, t) {
    let n2 = Object.entries(t), a = [], s = [];
    for (let i2 = 0, u2 = n2.length; i2 < u2; i2++) a.push(y(n2[i2][0])), s.push(E(e, r, n2[i2][1]));
    return C in t && (a.push(I(e.base, C)), s.push(Ue(rr(e.base), E(e, r, $e(t))))), v in t && (a.push(I(e.base, v)), s.push(je(tr(e.base), E(e, r, e.type === 1 ? re() : Qe(t))))), P in t && (a.push(I(e.base, P)), s.push($(t[P]))), R in t && (a.push(I(e.base, R)), s.push(t[R] ? H : J)), { k: a, v: s };
  }
  function Gr(e, r, t, n2, a) {
    return nr(t, n2, a, Zr(e, r, n2));
  }
  function Ea(e, r, t, n2) {
    return ke(t, E(e, r, n2.valueOf()));
  }
  function Ia(e, r, t, n2) {
    return De(t, n2, E(e, r, n2.buffer));
  }
  function Ra(e, r, t, n2) {
    return Fe(t, n2, E(e, r, n2.buffer));
  }
  function Pa(e, r, t, n2) {
    return Be(t, n2, E(e, r, n2.buffer));
  }
  function ln(e, r, t, n2) {
    let a = Z(n2, e.base.features);
    return Ve(t, n2, a ? Zr(e, r, a) : o);
  }
  function xa(e, r, t, n2) {
    let a = Z(n2, e.base.features);
    return Me(t, n2, a ? Zr(e, r, a) : o);
  }
  function Ta(e, r, t, n2) {
    let a = [], s = [];
    for (let [i2, u2] of n2.entries()) a.push(E(e, r, i2)), s.push(E(e, r, u2));
    return or(e.base, t, a, s);
  }
  function Oa(e, r, t, n2) {
    let a = [];
    for (let s of n2.keys()) a.push(E(e, r, s));
    return Le(t, a);
  }
  function wa(e, r, t, n2) {
    let a = Ye(t, k(e.base, 4), []);
    return e.type === 1 || (Qr(e), n2.on({ next: (s) => {
      if (e.state.alive) {
        let i2 = W(e, r, s);
        i2 && se(e, qe(t, i2));
      }
    }, throw: (s) => {
      if (e.state.alive) {
        let i2 = W(e, r, s);
        i2 && se(e, We(t, i2));
      }
      be(e);
    }, return: (s) => {
      if (e.state.alive) {
        let i2 = W(e, r, s);
        i2 && se(e, Ge(t, i2));
      }
      be(e);
    } })), a;
  }
  function ha(e, r, t) {
    if (this.state.alive) {
      let n2 = W(this, r, t);
      n2 && se(this, c(23, e, o, o, o, o, o, [k(this.base, 2), n2], o, o, o, o)), be(this);
    }
  }
  function za(e, r, t) {
    if (this.state.alive) {
      let n2 = W(this, r, t);
      n2 && se(this, c(24, e, o, o, o, o, o, [k(this.base, 3), n2], o, o, o, o));
    }
    be(this);
  }
  function _a(e, r, t, n2) {
    let a = zr(e.base, {});
    return e.type === 2 && (Qr(e), n2.then(ha.bind(e, a, r), za.bind(e, a, r))), zt(e.base, t, a);
  }
  function ka(e, r, t, n2, a) {
    for (let s = 0, i2 = a.length; s < i2; s++) {
      let u2 = a[s];
      if (u2.parse.sync && u2.test(n2)) return ce(t, u2.tag, u2.parse.sync(n2, new Kr(e, r), { id: t }));
    }
    return o;
  }
  function Da(e, r, t, n2, a) {
    for (let s = 0, i2 = a.length; s < i2; s++) {
      let u2 = a[s];
      if (u2.parse.stream && u2.test(n2)) return ce(t, u2.tag, u2.parse.stream(n2, new Hr(e, r), { id: t }));
    }
    return o;
  }
  function cn(e, r, t, n2) {
    let a = e.base.plugins;
    return a ? e.type === 1 ? ka(e, r, t, n2, a) : Da(e, r, t, n2, a) : o;
  }
  function Fa(e, r, t, n2) {
    let a = [];
    for (let s = 0, i2 = n2.v.length; s < i2; s++) a[s] = E(e, r, n2.v[s]);
    return Ke(t, a, n2.t, n2.d);
  }
  function Ba(e, r, t, n2, a) {
    switch (a) {
      case Object:
        return Gr(e, r, t, n2, false);
      case o:
        return Gr(e, r, t, n2, true);
      case Date:
        return he(t, n2);
      case Error:
      case EvalError:
      case RangeError:
      case ReferenceError:
      case SyntaxError:
      case TypeError:
      case URIError:
        return ln(e, r, t, n2);
      case Number:
      case Boolean:
      case String:
      case BigInt:
        return Ea(e, r, t, n2);
      case ArrayBuffer:
        return ar(e.base, t, n2);
      case Int8Array:
      case Int16Array:
      case Int32Array:
      case Uint8Array:
      case Uint16Array:
      case Uint32Array:
      case Uint8ClampedArray:
      case Float32Array:
      case Float64Array:
        return Ia(e, r, t, n2);
      case DataView:
        return Pa(e, r, t, n2);
      case Map:
        return Ta(e, r, t, n2);
      case Set:
        return Oa(e, r, t, n2);
      default:
        break;
    }
    if (a === Promise || n2 instanceof Promise) return _a(e, r, t, n2);
    let s = e.base.features;
    if (s & 32 && a === RegExp) return ze(t, n2);
    if (s & 16) switch (a) {
      case BigInt64Array:
      case BigUint64Array:
        return Ra(e, r, t, n2);
      default:
        break;
    }
    if (s & 1 && typeof AggregateError != "undefined" && (a === AggregateError || n2 instanceof AggregateError)) return xa(e, r, t, n2);
    if (n2 instanceof Error) return ln(e, r, t, n2);
    if (C in n2 || v in n2) return Gr(e, r, t, n2, !!a);
    throw new x(n2);
  }
  function Va(e, r, t, n2) {
    if (Array.isArray(n2)) return Aa(e, r, t, n2);
    if (Xe(n2)) return wa(e, r, t, n2);
    if (Ze(n2)) return Fa(e, r, t, n2);
    let a = n2.constructor;
    if (a === j) return E(e, r, n2.replacement);
    let s = cn(e, r, t, n2);
    return s || Ba(e, r, t, n2, a);
  }
  function Ma(e, r, t) {
    let n2 = Y(e.base, t);
    if (n2.type !== 0) return n2.value;
    let a = cn(e, r, n2.value, t);
    if (a) return a;
    throw new x(t);
  }
  function E(e, r, t) {
    if (r >= e.base.depthLimit) throw new Q(e.base.depthLimit);
    switch (typeof t) {
      case "boolean":
        return t ? H : J;
      case "undefined":
        return Ae;
      case "string":
        return $(t);
      case "number":
        return Oe(t);
      case "bigint":
        return we(t);
      case "object": {
        if (t) {
          let n2 = Y(e.base, t);
          return n2.type === 0 ? Va(e, r + 1, n2.value, t) : n2.value;
        }
        return Ee;
      }
      case "symbol":
        return I(e.base, t);
      case "function":
        return Ma(e, r, t);
      default:
        throw new x(t);
    }
  }
  function se(e, r) {
    e.state.initial ? e.state.buffer.push(r) : Xr(e, r, false);
  }
  function $r(e, r) {
    if (e.state.onError) e.state.onError(r);
    else throw r instanceof z ? r : new z(r);
  }
  function fn(e) {
    e.state.onDone && e.state.onDone();
  }
  function Xr(e, r, t) {
    try {
      e.state.onParse(r, t);
    } catch (n2) {
      $r(e, n2);
    }
  }
  function Qr(e) {
    e.state.pending++;
  }
  function be(e) {
    --e.state.pending <= 0 && fn(e);
  }
  function W(e, r, t) {
    try {
      return E(e, r, t);
    } catch (n2) {
      return $r(e, n2), o;
    }
  }
  function et(e, r) {
    let t = W(e, 0, r);
    t && (Xr(e, t, true), e.state.initial = false, La(e, e.state), e.state.pending <= 0 && Sr(e));
  }
  function La(e, r) {
    for (let t = 0, n2 = r.buffer.length; t < n2; t++) Xr(e, r.buffer[t], false);
  }
  function Sr(e) {
    e.state.alive && (fn(e), e.state.alive = false);
  }
  function Sn(e, r) {
    let t = A(r.plugins), n2 = Jr({ plugins: t, refs: r.refs, disabledFeatures: r.disabledFeatures, onParse(a, s) {
      let i2 = lr({ plugins: t, features: n2.base.features, scopeId: r.scopeId, markedRefs: n2.base.marked }), u2;
      try {
        u2 = fr(i2, a);
      } catch (l2) {
        r.onError && r.onError(l2);
        return;
      }
      r.onSerialize(u2, s);
    }, onError: r.onError, onDone: r.onDone });
    return et(n2, e), Sr.bind(null, n2);
  }
  var mr = class {
    constructor(r) {
      this.options = r;
      this.alive = true;
      this.flushed = false;
      this.done = false;
      this.pending = 0;
      this.cleanups = [];
      this.refs = /* @__PURE__ */ new Map();
      this.keys = /* @__PURE__ */ new Set();
      this.ids = 0;
      this.plugins = A(r.plugins);
    }
    write(r, t) {
      this.alive && !this.flushed && (this.pending++, this.keys.add(r), this.cleanups.push(Sn(t, { plugins: this.plugins, scopeId: this.options.scopeId, refs: this.refs, disabledFeatures: this.options.disabledFeatures, onError: this.options.onError, onSerialize: (n2, a) => {
        this.alive && this.options.onData(a ? this.options.globalIdentifier + '["' + y(r) + '"]=' + n2 : n2);
      }, onDone: () => {
        this.alive && (this.pending--, this.pending <= 0 && this.flushed && !this.done && this.options.onDone && (this.options.onDone(), this.done = true));
      } })));
    }
    getNextID() {
      for (; this.keys.has("" + this.ids); ) this.ids++;
      return "" + this.ids;
    }
    push(r) {
      let t = this.getNextID();
      return this.write(t, r), t;
    }
    flush() {
      this.alive && (this.flushed = true, this.pending <= 0 && !this.done && this.options.onDone && (this.options.onDone(), this.done = true));
    }
    close() {
      if (this.alive) {
        for (let r = 0, t = this.cleanups.length; r < t; r++) this.cleanups[r]();
        !this.done && this.options.onDone && (this.options.onDone(), this.done = true), this.alive = false;
      }
    }
  };

  // node_modules/seroval-plugins/dist/esm/production/web.mjs
  var u = (e) => {
    let r = new AbortController(), a = r.abort.bind(r);
    return e.then(a, a), r;
  };
  function E2(e) {
    e(this.reason);
  }
  function D(e) {
    this.addEventListener("abort", E2.bind(this, e), { once: true });
  }
  function c2(e) {
    return new Promise(D.bind(e));
  }
  var i = {};
  var F2 = ai({ tag: "seroval-plugins/web/AbortControllerFactoryPlugin", test(e) {
    return e === i;
  }, parse: { sync() {
    return i;
  }, async async() {
    return await Promise.resolve(i);
  }, stream() {
    return i;
  } }, serialize() {
    return u.toString();
  }, deserialize() {
    return u;
  } });
  var A2 = ai({ tag: "seroval-plugins/web/AbortSignal", extends: [F2], test(e) {
    return typeof AbortSignal == "undefined" ? false : e instanceof AbortSignal;
  }, parse: { sync(e, r) {
    return e.aborted ? { reason: r.parse(e.reason) } : {};
  }, async async(e, r) {
    if (e.aborted) return { reason: await r.parse(e.reason) };
    let a = await c2(e);
    return { reason: await r.parse(a) };
  }, stream(e, r) {
    if (e.aborted) return { reason: r.parse(e.reason) };
    let a = c2(e);
    return { factory: r.parse(i), controller: r.parse(a) };
  } }, serialize(e, r) {
    return e.reason ? "AbortSignal.abort(" + r.serialize(e.reason) + ")" : e.controller && e.factory ? "(" + r.serialize(e.factory) + ")(" + r.serialize(e.controller) + ").signal" : "(new AbortController).signal";
  }, deserialize(e, r) {
    return e.reason ? AbortSignal.abort(r.deserialize(e.reason)) : e.controller ? u(r.deserialize(e.controller)).signal : new AbortController().signal;
  } });
  var O = A2;
  var I2 = ai({ tag: "seroval-plugins/web/Blob", test(e) {
    return typeof Blob == "undefined" ? false : e instanceof Blob;
  }, parse: { async async(e, r) {
    return { type: await r.parse(e.type), buffer: await r.parse(await e.arrayBuffer()) };
  } }, serialize(e, r) {
    return "new Blob([" + r.serialize(e.buffer) + "],{type:" + r.serialize(e.type) + "})";
  }, deserialize(e, r) {
    return new Blob([r.deserialize(e.buffer)], { type: r.deserialize(e.type) });
  } });
  function d(e) {
    return { detail: e.detail, bubbles: e.bubbles, cancelable: e.cancelable, composed: e.composed };
  }
  var U2 = ai({ tag: "seroval-plugins/web/CustomEvent", test(e) {
    return typeof CustomEvent == "undefined" ? false : e instanceof CustomEvent;
  }, parse: { sync(e, r) {
    return { type: r.parse(e.type), options: r.parse(d(e)) };
  }, async async(e, r) {
    return { type: await r.parse(e.type), options: await r.parse(d(e)) };
  }, stream(e, r) {
    return { type: r.parse(e.type), options: r.parse(d(e)) };
  } }, serialize(e, r) {
    return "new CustomEvent(" + r.serialize(e.type) + "," + r.serialize(e.options) + ")";
  }, deserialize(e, r) {
    return new CustomEvent(r.deserialize(e.type), r.deserialize(e.options));
  } });
  var L2 = U2;
  var _2 = ai({ tag: "seroval-plugins/web/DOMException", test(e) {
    return typeof DOMException == "undefined" ? false : e instanceof DOMException;
  }, parse: { sync(e, r) {
    return { name: r.parse(e.name), message: r.parse(e.message) };
  }, async async(e, r) {
    return { name: await r.parse(e.name), message: await r.parse(e.message) };
  }, stream(e, r) {
    return { name: r.parse(e.name), message: r.parse(e.message) };
  } }, serialize(e, r) {
    return "new DOMException(" + r.serialize(e.message) + "," + r.serialize(e.name) + ")";
  }, deserialize(e, r) {
    return new DOMException(r.deserialize(e.message), r.deserialize(e.name));
  } });
  var q2 = _2;
  function f2(e) {
    return { bubbles: e.bubbles, cancelable: e.cancelable, composed: e.composed };
  }
  var k2 = ai({ tag: "seroval-plugins/web/Event", test(e) {
    return typeof Event == "undefined" ? false : e instanceof Event;
  }, parse: { sync(e, r) {
    return { type: r.parse(e.type), options: r.parse(f2(e)) };
  }, async async(e, r) {
    return { type: await r.parse(e.type), options: await r.parse(f2(e)) };
  }, stream(e, r) {
    return { type: r.parse(e.type), options: r.parse(f2(e)) };
  } }, serialize(e, r) {
    return "new Event(" + r.serialize(e.type) + "," + r.serialize(e.options) + ")";
  }, deserialize(e, r) {
    return new Event(r.deserialize(e.type), r.deserialize(e.options));
  } });
  var Y2 = k2;
  var V = ai({ tag: "seroval-plugins/web/File", test(e) {
    return typeof File == "undefined" ? false : e instanceof File;
  }, parse: { async async(e, r) {
    return { name: await r.parse(e.name), options: await r.parse({ type: e.type, lastModified: e.lastModified }), buffer: await r.parse(await e.arrayBuffer()) };
  } }, serialize(e, r) {
    return "new File([" + r.serialize(e.buffer) + "]," + r.serialize(e.name) + "," + r.serialize(e.options) + ")";
  }, deserialize(e, r) {
    return new File([r.deserialize(e.buffer)], r.deserialize(e.name), r.deserialize(e.options));
  } });
  var m2 = V;
  function y2(e) {
    let r = [];
    return e.forEach((a, t) => {
      r.push([t, a]);
    }), r;
  }
  var o2 = {};
  var v2 = (e, r = new FormData(), a = 0, t = e.length, s) => {
    for (; a < t; a++) s = e[a], r.append(s[0], s[1]);
    return r;
  };
  var G = ai({ tag: "seroval-plugins/web/FormDataFactory", test(e) {
    return e === o2;
  }, parse: { sync() {
    return o2;
  }, async async() {
    return await Promise.resolve(o2);
  }, stream() {
    return o2;
  } }, serialize() {
    return v2.toString();
  }, deserialize() {
    return o2;
  } });
  var J2 = ai({ tag: "seroval-plugins/web/FormData", extends: [m2, G], test(e) {
    return typeof FormData == "undefined" ? false : e instanceof FormData;
  }, parse: { sync(e, r) {
    return { factory: r.parse(o2), entries: r.parse(y2(e)) };
  }, async async(e, r) {
    return { factory: await r.parse(o2), entries: await r.parse(y2(e)) };
  }, stream(e, r) {
    return { factory: r.parse(o2), entries: r.parse(y2(e)) };
  } }, serialize(e, r) {
    return "(" + r.serialize(e.factory) + ")(" + r.serialize(e.entries) + ")";
  }, deserialize(e, r) {
    return v2(r.deserialize(e.entries));
  } });
  var K = J2;
  function g(e) {
    let r = [];
    return e.forEach((a, t) => {
      r.push([t, a]);
    }), r;
  }
  var W2 = ai({ tag: "seroval-plugins/web/Headers", test(e) {
    return typeof Headers == "undefined" ? false : e instanceof Headers;
  }, parse: { sync(e, r) {
    return { value: r.parse(g(e)) };
  }, async async(e, r) {
    return { value: await r.parse(g(e)) };
  }, stream(e, r) {
    return { value: r.parse(g(e)) };
  } }, serialize(e, r) {
    return "new Headers(" + r.serialize(e.value) + ")";
  }, deserialize(e, r) {
    return new Headers(r.deserialize(e.value));
  } });
  var l = W2;
  var Z2 = ai({ tag: "seroval-plugins/web/ImageData", test(e) {
    return typeof ImageData == "undefined" ? false : e instanceof ImageData;
  }, parse: { sync(e, r) {
    return { data: r.parse(e.data), width: r.parse(e.width), height: r.parse(e.height), options: r.parse({ colorSpace: e.colorSpace }) };
  }, async async(e, r) {
    return { data: await r.parse(e.data), width: await r.parse(e.width), height: await r.parse(e.height), options: await r.parse({ colorSpace: e.colorSpace }) };
  }, stream(e, r) {
    return { data: r.parse(e.data), width: r.parse(e.width), height: r.parse(e.height), options: r.parse({ colorSpace: e.colorSpace }) };
  } }, serialize(e, r) {
    return "new ImageData(" + r.serialize(e.data) + "," + r.serialize(e.width) + "," + r.serialize(e.height) + "," + r.serialize(e.options) + ")";
  }, deserialize(e, r) {
    return new ImageData(r.deserialize(e.data), r.deserialize(e.width), r.deserialize(e.height), r.deserialize(e.options));
  } });
  var n = {};
  var P2 = (e) => new ReadableStream({ start: (r) => {
    e.on({ next: (a) => {
      try {
        r.enqueue(a);
      } catch (t) {
      }
    }, throw: (a) => {
      r.error(a);
    }, return: () => {
      try {
        r.close();
      } catch (a) {
      }
    } });
  } });
  var x2 = ai({ tag: "seroval-plugins/web/ReadableStreamFactory", test(e) {
    return e === n;
  }, parse: { sync() {
    return n;
  }, async async() {
    return await Promise.resolve(n);
  }, stream() {
    return n;
  } }, serialize() {
    return P2.toString();
  }, deserialize() {
    return n;
  } });
  function w2(e) {
    let r = re(), a = e.getReader();
    async function t() {
      try {
        let s = await a.read();
        s.done ? r.return(s.value) : (r.next(s.value), await t());
      } catch (s) {
        r.throw(s);
      }
    }
    return t().catch(() => {
    }), r;
  }
  var ee2 = ai({ tag: "seroval/plugins/web/ReadableStream", extends: [x2], test(e) {
    return typeof ReadableStream == "undefined" ? false : e instanceof ReadableStream;
  }, parse: { sync(e, r) {
    return { factory: r.parse(n), stream: r.parse(re()) };
  }, async async(e, r) {
    return { factory: await r.parse(n), stream: await r.parse(w2(e)) };
  }, stream(e, r) {
    return { factory: r.parse(n), stream: r.parse(w2(e)) };
  } }, serialize(e, r) {
    return "(" + r.serialize(e.factory) + ")(" + r.serialize(e.stream) + ")";
  }, deserialize(e, r) {
    let a = r.deserialize(e.stream);
    return P2(a);
  } });
  var p = ee2;
  function N(e, r) {
    return { body: r, cache: e.cache, credentials: e.credentials, headers: e.headers, integrity: e.integrity, keepalive: e.keepalive, method: e.method, mode: e.mode, redirect: e.redirect, referrer: e.referrer, referrerPolicy: e.referrerPolicy };
  }
  var ae2 = ai({ tag: "seroval-plugins/web/Request", extends: [p, l], test(e) {
    return typeof Request == "undefined" ? false : e instanceof Request;
  }, parse: { async async(e, r) {
    return { url: await r.parse(e.url), options: await r.parse(N(e, e.body && !e.bodyUsed ? await e.clone().arrayBuffer() : null)) };
  }, stream(e, r) {
    return { url: r.parse(e.url), options: r.parse(N(e, e.body && !e.bodyUsed ? e.clone().body : null)) };
  } }, serialize(e, r) {
    return "new Request(" + r.serialize(e.url) + "," + r.serialize(e.options) + ")";
  }, deserialize(e, r) {
    return new Request(r.deserialize(e.url), r.deserialize(e.options));
  } });
  var te = ae2;
  function h2(e) {
    return { headers: e.headers, status: e.status, statusText: e.statusText };
  }
  var oe2 = ai({ tag: "seroval-plugins/web/Response", extends: [p, l], test(e) {
    return typeof Response == "undefined" ? false : e instanceof Response;
  }, parse: { async async(e, r) {
    return { body: await r.parse(e.body && !e.bodyUsed ? await e.clone().arrayBuffer() : null), options: await r.parse(h2(e)) };
  }, stream(e, r) {
    return { body: r.parse(e.body && !e.bodyUsed ? e.clone().body : null), options: r.parse(h2(e)) };
  } }, serialize(e, r) {
    return "new Response(" + r.serialize(e.body) + "," + r.serialize(e.options) + ")";
  }, deserialize(e, r) {
    return new Response(r.deserialize(e.body), r.deserialize(e.options));
  } });
  var ne = oe2;
  var le2 = ai({ tag: "seroval-plugins/web/URL", test(e) {
    return typeof URL == "undefined" ? false : e instanceof URL;
  }, parse: { sync(e, r) {
    return { value: r.parse(e.href) };
  }, async async(e, r) {
    return { value: await r.parse(e.href) };
  }, stream(e, r) {
    return { value: r.parse(e.href) };
  } }, serialize(e, r) {
    return "new URL(" + r.serialize(e.value) + ")";
  }, deserialize(e, r) {
    return new URL(r.deserialize(e.value));
  } });
  var pe2 = le2;
  var de = ai({ tag: "seroval-plugins/web/URLSearchParams", test(e) {
    return typeof URLSearchParams == "undefined" ? false : e instanceof URLSearchParams;
  }, parse: { sync(e, r) {
    return { value: r.parse(e.toString()) };
  }, async async(e, r) {
    return { value: await r.parse(e.toString()) };
  }, stream(e, r) {
    return { value: r.parse(e.toString()) };
  } }, serialize(e, r) {
    return "new URLSearchParams(" + r.serialize(e.value) + ")";
  }, deserialize(e, r) {
    return new URLSearchParams(r.deserialize(e.value));
  } });
  var fe2 = de;

  // node_modules/solid-js/web/dist/server.js
  var booleans = [
    "allowfullscreen",
    "async",
    "alpha",
    "autofocus",
    "autoplay",
    "checked",
    "controls",
    "default",
    "disabled",
    "formnovalidate",
    "hidden",
    "indeterminate",
    "inert",
    "ismap",
    "loop",
    "multiple",
    "muted",
    "nomodule",
    "novalidate",
    "open",
    "playsinline",
    "readonly",
    "required",
    "reversed",
    "seamless",
    "selected",
    "adauctionheaders",
    "browsingtopics",
    "credentialless",
    "defaultchecked",
    "defaultmuted",
    "defaultselected",
    "defer",
    "disablepictureinpicture",
    "disableremoteplayback",
    "preservespitch",
    "shadowrootclonable",
    "shadowrootcustomelementregistry",
    "shadowrootdelegatesfocus",
    "shadowrootserializable",
    "sharedstoragewritable"
  ];
  var Properties = /* @__PURE__ */ new Set([
    "className",
    "value",
    "readOnly",
    "noValidate",
    "formNoValidate",
    "isMap",
    "noModule",
    "playsInline",
    "adAuctionHeaders",
    "allowFullscreen",
    "browsingTopics",
    "defaultChecked",
    "defaultMuted",
    "defaultSelected",
    "disablePictureInPicture",
    "disableRemotePlayback",
    "preservesPitch",
    "shadowRootClonable",
    "shadowRootCustomElementRegistry",
    "shadowRootDelegatesFocus",
    "shadowRootSerializable",
    "sharedStorageWritable",
    ...booleans
  ]);
  var ES2017FLAG = M.AggregateError | M.BigIntTypedArray;
  var GLOBAL_IDENTIFIER = "_$HY.r";
  function createSerializer({
    onData,
    onDone,
    scopeId,
    onError,
    plugins: customPlugins
  }) {
    const defaultPlugins = [
      O,
      L2,
      q2,
      Y2,
      K,
      l,
      p,
      te,
      ne,
      fe2,
      pe2
    ];
    const allPlugins = customPlugins ? [...customPlugins, ...defaultPlugins] : defaultPlugins;
    return new mr({
      scopeId,
      plugins: allPlugins,
      globalIdentifier: GLOBAL_IDENTIFIER,
      disabledFeatures: ES2017FLAG,
      onData,
      onDone,
      onError
    });
  }
  function getLocalHeaderScript(id) {
    return dn(id) + ";";
  }
  function renderToString(code, options = {}) {
    const {
      renderId
    } = options;
    let scripts = "";
    const serializer = createSerializer({
      scopeId: renderId,
      plugins: options.plugins,
      onData(script) {
        if (!scripts) {
          scripts = getLocalHeaderScript(renderId);
        }
        scripts += script + ";";
      },
      onError: options.onError
    });
    sharedConfig.context = {
      id: renderId || "",
      count: 0,
      suspense: {},
      lazy: {},
      assets: [],
      nonce: options.nonce,
      serialize(id, p2) {
        !sharedConfig.context.noHydrate && serializer.write(id, p2);
      },
      roots: 0,
      nextRoot() {
        return this.renderId + "i-" + this.roots++;
      }
    };
    let html2 = createRoot((d2) => {
      setTimeout(d2);
      return resolveSSRNode(escape(code()));
    });
    sharedConfig.context.noHydrate = true;
    serializer.close();
    html2 = injectAssets(sharedConfig.context.assets, html2);
    if (scripts.length) html2 = injectScripts(html2, scripts, options.nonce);
    return html2;
  }
  function ssr(t, ...nodes) {
    if (nodes.length) {
      let result = "";
      for (let i2 = 0; i2 < nodes.length; i2++) {
        result += t[i2];
        const node = nodes[i2];
        if (node !== void 0) result += resolveSSRNode(node);
      }
      t = result + t[nodes.length];
    }
    return {
      t
    };
  }
  function ssrAttribute(key, value, isBoolean) {
    return isBoolean ? value ? " " + key : "" : value != null ? ` ${key}="${value}"` : "";
  }
  function escape(s, attr) {
    const t = typeof s;
    if (t !== "string") {
      if (!attr && t === "function") return escape(s());
      if (!attr && Array.isArray(s)) {
        s = s.slice();
        for (let i2 = 0; i2 < s.length; i2++) s[i2] = escape(s[i2]);
        return s;
      }
      if (attr && t === "boolean") return String(s);
      return s;
    }
    const delim = attr ? '"' : "<";
    const escDelim = attr ? "&quot;" : "&lt;";
    let iDelim = s.indexOf(delim);
    let iAmp = s.indexOf("&");
    if (iDelim < 0 && iAmp < 0) return s;
    let left = 0, out = "";
    while (iDelim >= 0 && iAmp >= 0) {
      if (iDelim < iAmp) {
        if (left < iDelim) out += s.substring(left, iDelim);
        out += escDelim;
        left = iDelim + 1;
        iDelim = s.indexOf(delim, left);
      } else {
        if (left < iAmp) out += s.substring(left, iAmp);
        out += "&amp;";
        left = iAmp + 1;
        iAmp = s.indexOf("&", left);
      }
    }
    if (iDelim >= 0) {
      do {
        if (left < iDelim) out += s.substring(left, iDelim);
        out += escDelim;
        left = iDelim + 1;
        iDelim = s.indexOf(delim, left);
      } while (iDelim >= 0);
    } else while (iAmp >= 0) {
      if (left < iAmp) out += s.substring(left, iAmp);
      out += "&amp;";
      left = iAmp + 1;
      iAmp = s.indexOf("&", left);
    }
    return left < s.length ? out + s.substring(left) : out;
  }
  function resolveSSRNode(node, top) {
    const t = typeof node;
    if (t === "string") return node;
    if (node == null || t === "boolean") return "";
    if (Array.isArray(node)) {
      let prev = {};
      let mapped = "";
      for (let i2 = 0, len = node.length; i2 < len; i2++) {
        if (!top && typeof prev !== "object" && typeof node[i2] !== "object") mapped += `<!--!$-->`;
        mapped += resolveSSRNode(prev = node[i2]);
      }
      return mapped;
    }
    if (t === "object") return node.t;
    if (t === "function") return resolveSSRNode(node());
    return String(node);
  }
  function injectAssets(assets, html2) {
    if (!assets || !assets.length) return html2;
    let out = "";
    for (let i2 = 0, len = assets.length; i2 < len; i2++) out += assets[i2]();
    const index = html2.indexOf("</head>");
    if (index === -1) return html2;
    return html2.slice(0, index) + out + html2.slice(index);
  }
  function injectScripts(html2, scripts, nonce) {
    const tag = `<script${nonce ? ` nonce="${nonce}"` : ""}>${scripts}</script>`;
    const index = html2.indexOf("<!--xs-->");
    if (index > -1) {
      return html2.slice(0, index) + tag + html2.slice(index);
    }
    return html2 + tag;
  }

  // App.compiled.js
  var _tmpl$ = ["<li", "><strong>", "</strong>: ", "</li>"];
  var _tmpl$2 = ['<p class="sub">', "</p>"];
  var _tmpl$3 = ['<div id="app"><h1>', "</h1>", "<ul>", "</ul><footer>count: ", "</footer></div>"];
  function Item(props) {
    const label = createMemo(() => props.name.toUpperCase());
    return ssr(_tmpl$, ssrAttribute("class", props.active ? "item active" : "item", false), escape(label()), escape(props.value));
  }
  function App(props) {
    const [count] = createSignal(props.items.length);
    return ssr(_tmpl$3, escape(props.title), escape(createComponent(Show, {
      get when() {
        return props.subtitle;
      },
      get children() {
        return ssr(_tmpl$2, escape(props.subtitle));
      }
    })), escape(createComponent(For, {
      get each() {
        return props.items;
      },
      children: (it2, i2) => createComponent(Item, {
        get name() {
          return it2.name;
        },
        get value() {
          return it2.value;
        },
        get active() {
          return i2() === 0;
        }
      })
    })), escape(count()));
  }
  var html = renderToString(() => createComponent(App, {
    title: "Hello & <World>",
    subtitle: "a subtitle",
    items: [{
      name: "alpha",
      value: 1
    }, {
      name: "beta",
      value: 2
    }, {
      name: "gamma",
      value: 3
    }]
  }));
  print("SOLID_OK[" + html + "]");
})();
