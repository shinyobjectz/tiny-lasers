(() => {
  // node_modules/preact/dist/preact.mjs
  var n;
  var l;
  var u;
  var t;
  var i;
  var r;
  var o;
  var e;
  var f;
  var c;
  var a;
  var s;
  var h;
  var p;
  var v;
  var y;
  var d = {};
  var w = [];
  var _ = /acit|ex(?:s|g|n|p|$)|rph|grid|ows|mnc|ntw|ine[ch]|zoo|^ord|itera/i;
  var g = Array.isArray;
  function m(n2, l4) {
    for (var u4 in l4) n2[u4] = l4[u4];
    return n2;
  }
  function b(n2) {
    n2 && n2.parentNode && n2.parentNode.removeChild(n2);
  }
  function k(l4, u4, t3) {
    var i4, r4, o4, e3 = {};
    for (o4 in u4) "key" == o4 ? i4 = u4[o4] : "ref" == o4 ? r4 = u4[o4] : e3[o4] = u4[o4];
    if (arguments.length > 2 && (e3.children = arguments.length > 3 ? n.call(arguments, 2) : t3), "function" == typeof l4 && null != l4.defaultProps) for (o4 in l4.defaultProps) void 0 === e3[o4] && (e3[o4] = l4.defaultProps[o4]);
    return x(l4, e3, i4, r4, null);
  }
  function x(n2, t3, i4, r4, o4) {
    var e3 = { type: n2, props: t3, key: i4, ref: r4, __k: null, __: null, __b: 0, __e: null, __c: null, constructor: void 0, __v: null == o4 ? ++u : o4, __i: -1, __u: 0 };
    return null == o4 && null != l.vnode && l.vnode(e3), e3;
  }
  function S(n2) {
    return n2.children;
  }
  function C(n2, l4) {
    this.props = n2, this.context = l4;
  }
  function $(n2, l4) {
    if (null == l4) return n2.__ ? $(n2.__, n2.__i + 1) : null;
    for (var u4; l4 < n2.__k.length; l4++) if (null != (u4 = n2.__k[l4]) && null != u4.__e) return u4.__e;
    return "function" == typeof n2.type ? $(n2) : null;
  }
  function I(n2) {
    if (n2.__P && n2.__d) {
      var u4 = n2.__v, t3 = u4.__e, i4 = [], r4 = [], o4 = m({}, u4);
      o4.__v = u4.__v + 1, l.vnode && l.vnode(o4), q(n2.__P, o4, u4, n2.__n, n2.__P.namespaceURI, 32 & u4.__u ? [t3] : null, i4, null == t3 ? $(u4) : t3, !!(32 & u4.__u), r4), o4.__v = u4.__v, o4.__.__k[o4.__i] = o4, D(i4, o4, r4), u4.__e = u4.__ = null, o4.__e != t3 && P(o4);
    }
  }
  function P(n2) {
    if (null != (n2 = n2.__) && null != n2.__c) return n2.__e = n2.__c.base = null, n2.__k.some(function(l4) {
      if (null != l4 && null != l4.__e) return n2.__e = n2.__c.base = l4.__e;
    }), P(n2);
  }
  function A(n2) {
    (!n2.__d && (n2.__d = true) && i.push(n2) && !H.__r++ || r != l.debounceRendering) && ((r = l.debounceRendering) || o)(H);
  }
  function H() {
    try {
      for (var n2, l4 = 1; i.length; ) i.length > l4 && i.sort(e), n2 = i.shift(), l4 = i.length, I(n2);
    } finally {
      i.length = H.__r = 0;
    }
  }
  function L(n2, l4, u4, t3, i4, r4, o4, e3, f4, c4, a4) {
    var s4, h4, p4, v4, y4, _4, g5, m4 = t3 && t3.__k || w, b3 = l4.length;
    for (f4 = T(u4, l4, m4, f4, b3), s4 = 0; s4 < b3; s4++) null != (p4 = u4.__k[s4]) && (h4 = -1 != p4.__i && m4[p4.__i] || d, p4.__i = s4, _4 = q(n2, p4, h4, i4, r4, o4, e3, f4, c4, a4), v4 = p4.__e, p4.ref && h4.ref != p4.ref && (h4.ref && J(h4.ref, null, p4), a4.push(p4.ref, p4.__c || v4, p4)), null == y4 && null != v4 && (y4 = v4), (g5 = !!(4 & p4.__u)) || h4.__k === p4.__k ? (f4 = j(p4, f4, n2, g5), g5 && h4.__e && (h4.__e = null)) : "function" == typeof p4.type && void 0 !== _4 ? f4 = _4 : v4 && (f4 = v4.nextSibling), p4.__u &= -7);
    return u4.__e = y4, f4;
  }
  function T(n2, l4, u4, t3, i4) {
    var r4, o4, e3, f4, c4, a4 = u4.length, s4 = a4, h4 = 0;
    for (n2.__k = new Array(i4), r4 = 0; r4 < i4; r4++) null != (o4 = l4[r4]) && "boolean" != typeof o4 && "function" != typeof o4 ? ("string" == typeof o4 || "number" == typeof o4 || "bigint" == typeof o4 || o4.constructor == String ? o4 = n2.__k[r4] = x(null, o4, null, null, null) : g(o4) ? o4 = n2.__k[r4] = x(S, { children: o4 }, null, null, null) : void 0 === o4.constructor && o4.__b > 0 ? o4 = n2.__k[r4] = x(o4.type, o4.props, o4.key, o4.ref ? o4.ref : null, o4.__v) : n2.__k[r4] = o4, f4 = r4 + h4, o4.__ = n2, o4.__b = n2.__b + 1, e3 = null, -1 != (c4 = o4.__i = O(o4, u4, f4, s4)) && (s4--, (e3 = u4[c4]) && (e3.__u |= 2)), null == e3 || null == e3.__v ? (-1 == c4 && (i4 > a4 ? h4-- : i4 < a4 && h4++), "function" != typeof o4.type && (o4.__u |= 4)) : c4 != f4 && (c4 == f4 - 1 ? h4-- : c4 == f4 + 1 ? h4++ : (c4 > f4 ? h4-- : h4++, o4.__u |= 4))) : n2.__k[r4] = null;
    if (s4) for (r4 = 0; r4 < a4; r4++) null != (e3 = u4[r4]) && 0 == (2 & e3.__u) && (e3.__e == t3 && (t3 = $(e3)), K(e3, e3));
    return t3;
  }
  function j(n2, l4, u4, t3) {
    var i4, r4;
    if ("function" == typeof n2.type) {
      for (i4 = n2.__k, r4 = 0; i4 && r4 < i4.length; r4++) i4[r4] && (i4[r4].__ = n2, l4 = j(i4[r4], l4, u4, t3));
      return l4;
    }
    n2.__e != l4 && (t3 && (l4 && n2.type && !l4.parentNode && (l4 = $(n2)), u4.insertBefore(n2.__e, l4 || null)), l4 = n2.__e);
    do {
      l4 = l4 && l4.nextSibling;
    } while (null != l4 && 8 == l4.nodeType);
    return l4;
  }
  function F(n2, l4) {
    return l4 = l4 || [], null == n2 || "boolean" == typeof n2 || (g(n2) ? n2.some(function(n3) {
      F(n3, l4);
    }) : l4.push(n2)), l4;
  }
  function O(n2, l4, u4, t3) {
    var i4, r4, o4, e3 = n2.key, f4 = n2.type, c4 = l4[u4], a4 = null != c4 && 0 == (2 & c4.__u);
    if (null === c4 && null == e3 || a4 && e3 == c4.key && f4 == c4.type) return u4;
    if (t3 > (a4 ? 1 : 0)) {
      for (i4 = u4 - 1, r4 = u4 + 1; i4 >= 0 || r4 < l4.length; ) if (null != (c4 = l4[o4 = i4 >= 0 ? i4-- : r4++]) && 0 == (2 & c4.__u) && e3 == c4.key && f4 == c4.type) return o4;
    }
    return -1;
  }
  function z(n2, l4, u4) {
    "-" == l4[0] ? n2.setProperty(l4, null == u4 ? "" : u4) : n2[l4] = null == u4 ? "" : "number" != typeof u4 || _.test(l4) ? u4 : u4 + "px";
  }
  function N(n2, l4, u4, t3, i4) {
    var r4, o4;
    n: if ("style" == l4) if ("string" == typeof u4) n2.style.cssText = u4;
    else {
      if ("string" == typeof t3 && (n2.style.cssText = t3 = ""), t3) for (l4 in t3) u4 && l4 in u4 || z(n2.style, l4, "");
      if (u4) for (l4 in u4) t3 && u4[l4] == t3[l4] || z(n2.style, l4, u4[l4]);
    }
    else if ("o" == l4[0] && "n" == l4[1]) r4 = l4 != (l4 = l4.replace(s, "$1")), o4 = l4.toLowerCase(), l4 = o4 in n2 || "onFocusOut" == l4 || "onFocusIn" == l4 ? o4.slice(2) : l4.slice(2), n2.l || (n2.l = {}), n2.l[l4 + r4] = u4, u4 ? t3 ? u4[a] = t3[a] : (u4[a] = h, n2.addEventListener(l4, r4 ? v : p, r4)) : n2.removeEventListener(l4, r4 ? v : p, r4);
    else {
      if ("http://www.w3.org/2000/svg" == i4) l4 = l4.replace(/xlink(H|:h)/, "h").replace(/sName$/, "s");
      else if ("width" != l4 && "height" != l4 && "href" != l4 && "list" != l4 && "form" != l4 && "tabIndex" != l4 && "download" != l4 && "rowSpan" != l4 && "colSpan" != l4 && "role" != l4 && "popover" != l4 && l4 in n2) try {
        n2[l4] = null == u4 ? "" : u4;
        break n;
      } catch (n3) {
      }
      "function" == typeof u4 || (null == u4 || false === u4 && "-" != l4[4] ? n2.removeAttribute(l4) : n2.setAttribute(l4, "popover" == l4 && 1 == u4 ? "" : u4));
    }
  }
  function V(n2) {
    return function(u4) {
      if (this.l) {
        var t3 = this.l[u4.type + n2];
        if (null == u4[c]) u4[c] = h++;
        else if (u4[c] < t3[a]) return;
        return t3(l.event ? l.event(u4) : u4);
      }
    };
  }
  function q(n2, u4, t3, i4, r4, o4, e3, f4, c4, a4) {
    var s4, h4, p4, v4, y4, d4, _4, k4, x4, M4, $3, I3, P5, A5, H4, T4, j4 = u4.type;
    if (void 0 !== u4.constructor) return null;
    128 & t3.__u && (c4 = !!(32 & t3.__u), o4 = [f4 = u4.__e = t3.__e]), (s4 = l.__b) && s4(u4);
    n: if ("function" == typeof j4) {
      h4 = e3.length;
      try {
        if (x4 = u4.props, M4 = j4.prototype && j4.prototype.render, $3 = (s4 = j4.contextType) && i4[s4.__c], I3 = s4 ? $3 ? $3.props.value : s4.__ : i4, t3.__c ? k4 = (p4 = u4.__c = t3.__c).__ = p4.__E : (M4 ? u4.__c = p4 = new j4(x4, I3) : (u4.__c = p4 = new C(x4, I3), p4.constructor = j4, p4.render = Q), $3 && $3.sub(p4), p4.state || (p4.state = {}), p4.__n = i4, v4 = p4.__d = true, p4.__h = [], p4._sb = []), M4 && null == p4.__s && (p4.__s = p4.state), M4 && null != j4.getDerivedStateFromProps && (p4.__s == p4.state && (p4.__s = m({}, p4.__s)), m(p4.__s, j4.getDerivedStateFromProps(x4, p4.__s))), y4 = p4.props, d4 = p4.state, p4.__v = u4, v4) M4 && null == j4.getDerivedStateFromProps && null != p4.componentWillMount && p4.componentWillMount(), M4 && null != p4.componentDidMount && p4.__h.push(p4.componentDidMount);
        else {
          if (M4 && null == j4.getDerivedStateFromProps && x4 !== y4 && null != p4.componentWillReceiveProps && p4.componentWillReceiveProps(x4, I3), u4.__v == t3.__v || !p4.__e && null != p4.shouldComponentUpdate && false === p4.shouldComponentUpdate(x4, p4.__s, I3)) {
            u4.__v != t3.__v && (p4.props = x4, p4.state = p4.__s, p4.__d = false), u4.__e = t3.__e, u4.__k = t3.__k, u4.__k.some(function(n3) {
              n3 && (n3.__ = u4);
            }), w.push.apply(p4.__h, p4._sb), p4._sb = [], p4.__h.length && e3.push(p4);
            break n;
          }
          null != p4.componentWillUpdate && p4.componentWillUpdate(x4, p4.__s, I3), M4 && null != p4.componentDidUpdate && p4.__h.push(function() {
            p4.componentDidUpdate(y4, d4, _4);
          });
        }
        if (p4.context = I3, p4.props = x4, p4.__P = n2, p4.__e = false, P5 = l.__r, A5 = 0, M4) p4.state = p4.__s, p4.__d = false, P5 && P5(u4), s4 = p4.render(p4.props, p4.state, p4.context), w.push.apply(p4.__h, p4._sb), p4._sb = [];
        else do {
          p4.__d = false, P5 && P5(u4), s4 = p4.render(p4.props, p4.state, p4.context), p4.state = p4.__s;
        } while (p4.__d && ++A5 < 25);
        p4.state = p4.__s, null != p4.getChildContext && (i4 = m(m({}, i4), p4.getChildContext())), M4 && !v4 && null != p4.getSnapshotBeforeUpdate && (_4 = p4.getSnapshotBeforeUpdate(y4, d4)), H4 = null != s4 && s4.type === S && null == s4.key ? E(s4.props.children) : s4, f4 = L(n2, g(H4) ? H4 : [H4], u4, t3, i4, r4, o4, e3, f4, c4, a4), p4.base = u4.__e, u4.__u &= -161, p4.__h.length && e3.push(p4), k4 && (p4.__E = p4.__ = null);
      } catch (n3) {
        if (e3.length = h4, u4.__v = null, c4 || null != o4) if (n3.then) {
          for (u4.__u |= c4 ? 160 : 128; f4 && 8 == f4.nodeType && f4.nextSibling; ) f4 = f4.nextSibling;
          null != o4 && (o4[o4.indexOf(f4)] = null), u4.__e = f4;
        } else {
          if (null != o4) for (T4 = o4.length; T4--; ) b(o4[T4]);
          B(u4);
        }
        else u4.__e = t3.__e, !u4.__k && t3.__k && (u4.__k = t3.__k), n3.then || B(u4);
        l.__e(n3, u4, t3);
      }
    } else null == o4 && u4.__v == t3.__v ? (u4.__k = t3.__k, u4.__e = t3.__e) : f4 = u4.__e = G(t3.__e, u4, t3, i4, r4, o4, e3, c4, a4);
    return (s4 = l.diffed) && s4(u4), 128 & u4.__u ? void 0 : f4;
  }
  function B(n2) {
    n2 && (n2.__c && (n2.__c.__e = true), n2.__k && n2.__k.some(B));
  }
  function D(n2, u4, t3) {
    for (var i4 = 0; i4 < t3.length; i4++) J(t3[i4], t3[++i4], t3[++i4]);
    l.__c && l.__c(u4, n2), n2.some(function(u5) {
      try {
        n2 = u5.__h, u5.__h = [], n2.some(function(n3) {
          n3.call(u5);
        });
      } catch (n3) {
        l.__e(n3, u5.__v);
      }
    });
  }
  function E(n2) {
    return "object" != typeof n2 || null == n2 || n2.__b > 0 ? n2 : g(n2) ? n2.map(E) : void 0 !== n2.constructor ? null : m({}, n2);
  }
  function G(u4, t3, i4, r4, o4, e3, f4, c4, a4) {
    var s4, h4, p4, v4, y4, w4, _4, m4 = i4.props || d, k4 = t3.props, x4 = t3.type;
    if ("svg" == x4 ? o4 = "http://www.w3.org/2000/svg" : "math" == x4 ? o4 = "http://www.w3.org/1998/Math/MathML" : o4 || (o4 = "http://www.w3.org/1999/xhtml"), null != e3) {
      for (s4 = 0; s4 < e3.length; s4++) if ((y4 = e3[s4]) && "setAttribute" in y4 == !!x4 && (x4 ? y4.localName == x4 : 3 == y4.nodeType)) {
        u4 = y4, e3[s4] = null;
        break;
      }
    }
    if (null == u4) {
      if (null == x4) return document.createTextNode(k4);
      u4 = document.createElementNS(o4, x4, k4.is && k4), c4 && (l.__m && l.__m(t3, e3), c4 = false), e3 = null;
    }
    if (null == x4) m4 === k4 || c4 && u4.data == k4 || (u4.data = k4);
    else {
      if (e3 = "textarea" == x4 && null != k4.defaultValue ? null : e3 && n.call(u4.childNodes), !c4 && null != e3) for (m4 = {}, s4 = 0; s4 < u4.attributes.length; s4++) m4[(y4 = u4.attributes[s4]).name] = y4.value;
      for (s4 in m4) y4 = m4[s4], "dangerouslySetInnerHTML" == s4 ? p4 = y4 : "children" == s4 || s4 in k4 || "value" == s4 && "defaultValue" in k4 || "checked" == s4 && "defaultChecked" in k4 || N(u4, s4, null, y4, o4);
      for (s4 in k4) y4 = k4[s4], "children" == s4 ? v4 = y4 : "dangerouslySetInnerHTML" == s4 ? h4 = y4 : "value" == s4 ? w4 = y4 : "checked" == s4 ? _4 = y4 : c4 && "function" != typeof y4 || m4[s4] === y4 || N(u4, s4, y4, m4[s4], o4);
      if (h4) c4 || p4 && (h4.__html == p4.__html || h4.__html == u4.innerHTML) || (u4.innerHTML = h4.__html), t3.__k = [];
      else if (p4 && (u4.innerHTML = ""), L("template" == t3.type ? u4.content : u4, g(v4) ? v4 : [v4], t3, i4, r4, "foreignObject" == x4 ? "http://www.w3.org/1999/xhtml" : o4, e3, f4, e3 ? e3[0] : i4.__k && $(i4, 0), c4, a4), null != e3) for (s4 = e3.length; s4--; ) b(e3[s4]);
      c4 && "textarea" != x4 || (s4 = "value", "progress" == x4 && null == w4 ? u4.removeAttribute("value") : null != w4 && (w4 !== u4[s4] || "progress" == x4 && !w4 || "option" == x4 && w4 != m4[s4]) && N(u4, s4, w4, m4[s4], o4), s4 = "checked", null != _4 && _4 != u4[s4] && N(u4, s4, _4, m4[s4], o4));
    }
    return u4;
  }
  function J(n2, u4, t3) {
    try {
      if ("function" == typeof n2) {
        var i4 = "function" == typeof n2.__u;
        i4 && n2.__u(), i4 && null == u4 || (n2.__u = n2(u4));
      } else n2.current = u4;
    } catch (n3) {
      l.__e(n3, t3);
    }
  }
  function K(n2, u4, t3) {
    var i4, r4;
    if (l.unmount && l.unmount(n2), (i4 = n2.ref) && (i4.current && i4.current != n2.__e || J(i4, null, u4)), null != (i4 = n2.__c)) {
      if (i4.componentWillUnmount) try {
        i4.componentWillUnmount();
      } catch (n3) {
        l.__e(n3, u4);
      }
      i4.base = i4.__P = i4.__n = null;
    }
    if (i4 = n2.__k) for (r4 = 0; r4 < i4.length; r4++) i4[r4] && K(i4[r4], u4, t3 || "function" != typeof n2.type);
    t3 || b(n2.__e), n2.__c = n2.__ = n2.__e = void 0;
  }
  function Q(n2, l4, u4) {
    return this.constructor(n2, u4);
  }
  function X(n2) {
    function l4(n3) {
      var u4, t3;
      return this.getChildContext || (u4 = /* @__PURE__ */ new Set(), (t3 = {})[l4.__c] = this, this.getChildContext = function() {
        return t3;
      }, this.componentWillUnmount = function() {
        u4 = null;
      }, this.shouldComponentUpdate = function(n4) {
        this.props.value != n4.value && u4.forEach(function(n5) {
          n5.__e = true, A(n5);
        });
      }, this.sub = function(n4) {
        u4.add(n4);
        var l5 = n4.componentWillUnmount;
        n4.componentWillUnmount = function() {
          u4 && u4.delete(n4), l5 && l5.call(n4);
        };
      }), n3.children;
    }
    return l4.__c = "__cC" + y++, l4.__ = n2, l4.Provider = l4.__l = (l4.Consumer = function(n3, l5) {
      return n3.children(l5);
    }).contextType = l4, l4;
  }
  n = w.slice, l = { __e: function(n2, l4, u4, t3) {
    for (var i4, r4, o4; l4 = l4.__; ) if ((i4 = l4.__c) && !i4.__) try {
      if ((r4 = i4.constructor) && null != r4.getDerivedStateFromError && (i4.setState(r4.getDerivedStateFromError(n2)), o4 = i4.__d), null != i4.componentDidCatch && (i4.componentDidCatch(n2, t3 || {}), o4 = i4.__d), o4) return i4.__E = i4;
    } catch (l5) {
      n2 = l5;
    }
    throw n2;
  } }, u = 0, t = function(n2) {
    return null != n2 && void 0 === n2.constructor;
  }, C.prototype.setState = function(n2, l4) {
    var u4;
    u4 = null != this.__s && this.__s != this.state ? this.__s : this.__s = m({}, this.state), "function" == typeof n2 && (n2 = n2(m({}, u4), this.props)), n2 && m(u4, n2), null != n2 && this.__v && (l4 && this._sb.push(l4), A(this));
  }, C.prototype.forceUpdate = function(n2) {
    this.__v && (this.__e = true, n2 && this.__h.push(n2), A(this));
  }, C.prototype.render = S, i = [], o = "function" == typeof Promise ? Promise.prototype.then.bind(Promise.resolve()) : setTimeout, e = function(n2, l4) {
    return n2.__v.__b - l4.__v.__b;
  }, H.__r = 0, f = Math.random().toString(8), c = "__d" + f, a = "__a" + f, s = /(PointerCapture)$|Capture$/i, h = 0, p = V(false), v = V(true), y = 0;

  // node_modules/preact/hooks/dist/hooks.mjs
  var t2;
  var r2;
  var u2;
  var i2;
  var o2 = 0;
  var f2 = [];
  var c2 = l;
  var e2 = c2.__b;
  var a2 = c2.__r;
  var v2 = c2.diffed;
  var l2 = c2.__c;
  var m2 = c2.unmount;
  var p2 = c2.__;
  function s2(n2, t3) {
    c2.__h && c2.__h(r2, n2, o2 || t3), o2 = 0;
    var u4 = r2.__H || (r2.__H = { __: [], __h: [] });
    return n2 >= u4.__.length && u4.__.push({}), u4.__[n2];
  }
  function d2(n2) {
    return o2 = 1, y2(D2, n2);
  }
  function y2(n2, u4, i4) {
    var o4 = s2(t2++, 2);
    if (o4.t = n2, !o4.__c && (o4.__ = [i4 ? i4(u4) : D2(void 0, u4), function(n3) {
      var t3 = o4.__N ? o4.__N[0] : o4.__[0], r4 = o4.t(t3, n3);
      t3 !== r4 && (o4.__N = [r4, o4.__[1]], o4.__c.setState({}));
    }], o4.__c = r2, !r2.__f)) {
      var f4 = function(n3, t3, r4) {
        if (!o4.__c.__H) return true;
        var u5 = false, i5 = o4.__c.props !== n3;
        if (o4.__c.__H.__.some(function(n4) {
          if (n4.__N) {
            u5 = true;
            var t4 = n4.__[0];
            n4.__ = n4.__N, n4.__N = void 0, t4 !== n4.__[0] && (i5 = true);
          }
        }), c4) {
          var f5 = c4.call(this, n3, t3, r4);
          return u5 ? f5 || i5 : f5;
        }
        return !u5 || i5;
      };
      r2.__f = true;
      var c4 = r2.shouldComponentUpdate, e3 = r2.componentWillUpdate;
      r2.componentWillUpdate = function(n3, t3, r4) {
        if (this.__e) {
          var u5 = c4;
          c4 = void 0, f4(n3, t3, r4), c4 = u5;
        }
        e3 && e3.call(this, n3, t3, r4);
      }, r2.shouldComponentUpdate = f4;
    }
    return o4.__N || o4.__;
  }
  function T2(n2, r4) {
    var u4 = s2(t2++, 7);
    return C2(u4.__H, r4) && (u4.__ = n2(), u4.__H = r4, u4.__h = n2), u4.__;
  }
  function x2(n2) {
    var u4 = r2.context[n2.__c], i4 = s2(t2++, 9);
    return i4.c = n2, u4 ? (null == i4.__ && (i4.__ = true, u4.sub(r2)), u4.props.value) : n2.__;
  }
  function j2() {
    for (var n2; n2 = f2.shift(); ) {
      var t3 = n2.__H;
      if (n2.__P && t3) try {
        t3.__h.some(z2), t3.__h.some(B2), t3.__h = [];
      } catch (r4) {
        t3.__h = [], c2.__e(r4, n2.__v);
      }
    }
  }
  c2.__b = function(n2) {
    r2 = null, e2 && e2(n2);
  }, c2.__ = function(n2, t3) {
    n2 && t3.__k && t3.__k.__m && (n2.__m = t3.__k.__m), p2 && p2(n2, t3);
  }, c2.__r = function(n2) {
    a2 && a2(n2), t2 = 0;
    var i4 = (r2 = n2.__c).__H;
    i4 && (u2 === r2 ? (i4.__h = [], r2.__h = [], i4.__.some(function(n3) {
      n3.__N && (n3.__ = n3.__N), n3.u = n3.__N = void 0;
    })) : (i4.__h.length && j2(), t2 = 0)), u2 = r2;
  }, c2.diffed = function(n2) {
    v2 && v2(n2);
    var t3 = n2.__c;
    t3 && t3.__H && (t3.__H.__h.length && (1 !== f2.push(t3) && i2 === c2.requestAnimationFrame || ((i2 = c2.requestAnimationFrame) || w2)(j2)), t3.__H.__.some(function(n3) {
      n3.u && (n3.__H = n3.u, n3.u = void 0);
    })), u2 = r2 = null;
  }, c2.__c = function(n2, t3) {
    t3.some(function(n3) {
      try {
        n3.__h.some(z2), n3.__h = n3.__h.filter(function(n4) {
          return !n4.__ || B2(n4);
        });
      } catch (r4) {
        t3.some(function(n4) {
          n4.__h && (n4.__h = []);
        }), t3 = [], c2.__e(r4, n3.__v);
      }
    }), l2 && l2(n2, t3);
  }, c2.unmount = function(n2) {
    m2 && m2(n2);
    var t3, r4 = n2.__c;
    r4 && r4.__H && (r4.__H.__.some(function(n3) {
      try {
        z2(n3);
      } catch (n4) {
        t3 = n4;
      }
    }), r4.__H = void 0, t3 && c2.__e(t3, r4.__v));
  };
  var k2 = "function" == typeof requestAnimationFrame;
  function w2(n2) {
    var t3, r4 = function() {
      clearTimeout(u4), k2 && cancelAnimationFrame(t3), setTimeout(n2);
    }, u4 = setTimeout(r4, 35);
    k2 && (t3 = requestAnimationFrame(r4));
  }
  function z2(n2) {
    var t3 = r2, u4 = n2.__c;
    "function" == typeof u4 && (n2.__c = void 0, u4()), r2 = t3;
  }
  function B2(n2) {
    var t3 = r2;
    n2.__c = n2.__(), r2 = t3;
  }
  function C2(n2, t3) {
    return !n2 || n2.length !== t3.length || t3.some(function(t4, r4) {
      return t4 !== n2[r4];
    });
  }
  function D2(n2, t3) {
    return "function" == typeof t3 ? t3(n2) : t3;
  }

  // node_modules/preact/compat/dist/compat.mjs
  function g3(n2, t3) {
    for (var e3 in t3) n2[e3] = t3[e3];
    return n2;
  }
  function E2(n2, t3) {
    for (var e3 in n2) if ("__source" !== e3 && !(e3 in t3)) return true;
    for (var r4 in t3) if ("__source" !== r4 && n2[r4] !== t3[r4]) return true;
    return false;
  }
  function M2(n2, t3) {
    this.props = n2, this.context = t3;
  }
  function N2(n2, e3) {
    function r4(n3) {
      var t3 = this.props.ref;
      return t3 != n3.ref && t3 && ("function" == typeof t3 ? t3(null) : t3.current = null), e3 ? !e3(this.props, n3) || t3 != n3.ref : E2(this.props, n3);
    }
    function u4(e4) {
      return this.shouldComponentUpdate = r4, k(n2, e4);
    }
    return u4.displayName = "Memo(" + (n2.displayName || n2.name) + ")", u4.__f = u4.prototype.isReactComponent = true, u4.type = n2, u4;
  }
  (M2.prototype = new C()).isPureReactComponent = true, M2.prototype.shouldComponentUpdate = function(n2, t3) {
    return E2(this.props, n2) || E2(this.state, t3);
  };
  var T3 = l.__b;
  l.__b = function(n2) {
    n2.type && n2.type.__f && n2.ref && (n2.props.ref = n2.ref, n2.ref = null), T3 && T3(n2);
  };
  var A3 = "undefined" != typeof Symbol && Symbol.for && /* @__PURE__ */ Symbol.for("react.forward_ref") || 3911;
  var O2 = l.__e;
  l.__e = function(n2, t3, e3, r4) {
    if (n2.then) {
      for (var u4, o4 = t3; o4 = o4.__; ) if ((u4 = o4.__c) && u4.__c) return null == t3.__e && (t3.__e = e3.__e, t3.__k = e3.__k), u4.__c(n2, t3);
    }
    O2(n2, t3, e3, r4);
  };
  var U2 = l.unmount;
  function V2(n2, t3, e3) {
    return n2 && (n2.__c && n2.__c.__H && (n2.__c.__H.__.forEach(function(n3) {
      "function" == typeof n3.__c && n3.__c();
    }), n2.__c.__H = null), null != (n2 = g3({}, n2)).__c && (n2.__c.__P === e3 && (n2.__c.__P = t3), n2.__c.__e = true, n2.__c = null), n2.__k = n2.__k && n2.__k.map(function(n3) {
      return V2(n3, t3, e3);
    })), n2;
  }
  function W2(n2, t3, e3) {
    return n2 && e3 && (n2.__v = null, n2.__k = n2.__k && n2.__k.map(function(n3) {
      return W2(n3, t3, e3);
    }), n2.__c && n2.__c.__P === t3 && (n2.__e && e3.appendChild(n2.__e), n2.__c.__e = true, n2.__c.__P = e3)), n2;
  }
  function P3() {
    this.__u = 0, this.o = null, this.__b = null;
  }
  function j3(n2) {
    var t3 = n2.__ && n2.__.__c;
    return t3 && t3.__a && t3.__a(n2);
  }
  function B3() {
    this.i = null, this.l = null;
  }
  l.unmount = function(n2) {
    var t3 = n2.__c;
    t3 && (t3.__z = true), t3 && t3.__R && t3.__R(), t3 && 32 & n2.__u && (n2.type = null), U2 && U2(n2);
  }, (P3.prototype = new C()).__c = function(n2, t3) {
    var e3 = t3.__c, r4 = this;
    null == r4.o && (r4.o = []), r4.o.push(e3);
    var u4 = j3(r4.__v), o4 = false, i4 = function() {
      o4 || r4.__z || (o4 = true, e3.__R = null, u4 ? u4(f4) : f4());
    };
    e3.__R = i4;
    var l4 = e3.__P;
    e3.__P = null;
    var f4 = function() {
      if (!--r4.__u) {
        if (r4.state.__a) {
          var n3 = r4.state.__a;
          r4.__v.__k[0] = W2(n3, n3.__c.__P, n3.__c.__O);
        }
        var t4;
        for (r4.setState({ __a: r4.__b = null }); t4 = r4.o.pop(); ) t4.__P = l4, t4.forceUpdate();
      }
    };
    r4.__u++ || 32 & t3.__u || r4.setState({ __a: r4.__b = r4.__v.__k[0] }), n2.then(i4, i4);
  }, P3.prototype.componentWillUnmount = function() {
    this.o = [];
  }, P3.prototype.render = function(n2, e3) {
    var r4 = this.__v;
    if (!r4.__m) {
      for (var o4 = r4; o4.__; ) o4 = o4.__;
      o4 = o4.__m || (o4.__m = [0, 0]), r4.__m = [o4[1]++, 0];
    }
    if (this.__b) {
      if (r4.__k) {
        var i4 = document.createElement("div"), l4 = r4.__k[0].__c;
        r4.__k[0] = V2(this.__b, i4, l4.__O = l4.__P);
      }
      this.__b = null;
    }
    var f4 = e3.__a && k(S, null, n2.fallback);
    return f4 && (f4.__u &= -33), [k(S, null, e3.__a ? null : n2.children), f4];
  };
  var H2 = function(n2, t3, e3) {
    if (++e3[1] === e3[0] && n2.l.delete(t3), n2.props.revealOrder && ("t" !== n2.props.revealOrder[0] || !n2.l.size)) for (e3 = n2.i; e3; ) {
      for (; e3.length > 3; ) e3.pop()();
      if (e3[1] < e3[0]) break;
      n2.i = e3 = e3[2];
    }
  };
  (B3.prototype = new C()).__a = function(n2) {
    var t3 = this, e3 = j3(t3.__v), r4 = t3.l.get(n2);
    return r4[0]++, function(u4) {
      var o4 = function() {
        t3.props.revealOrder ? (r4.push(u4), H2(t3, n2, r4)) : u4();
      };
      e3 ? e3(o4) : o4();
    };
  }, B3.prototype.render = function(n2) {
    this.i = null, this.l = /* @__PURE__ */ new Map();
    var t3 = F(n2.children);
    n2.revealOrder && "b" === n2.revealOrder[0] && t3.reverse();
    for (var e3 = t3.length; e3--; ) this.l.set(t3[e3], this.i = [1, 0, this.i]);
    return n2.children;
  }, B3.prototype.componentDidUpdate = B3.prototype.componentDidMount = function() {
    var n2 = this;
    this.l.forEach(function(t3, e3) {
      H2(n2, e3, t3);
    });
  };
  var q3 = "undefined" != typeof Symbol && Symbol.for && /* @__PURE__ */ Symbol.for("react.element") || 60103;
  var G2 = /^(?:accent|alignment|arabic|baseline|cap|clip(?!PathU)|color|dominant|fill|flood|font|glyph(?!R)|horiz|image(!S)|letter|lighting|marker(?!H|W|U)|overline|paint|pointer|shape|stop|strikethrough|stroke|text(?!L)|transform|underline|unicode|units|v|vector|vert|word|writing|x(?!C))[A-Z]/;
  var J2 = /^on(Ani|Tra|Tou|BeforeInp|Compo)/;
  var K2 = /[A-Z0-9]/g;
  var Q2 = "undefined" != typeof document;
  var X2 = function(n2) {
    return ("undefined" != typeof Symbol && "symbol" == typeof /* @__PURE__ */ Symbol() ? /fil|che|rad/ : /fil|che|ra/).test(n2);
  };
  C.prototype.isReactComponent = true, ["componentWillMount", "componentWillReceiveProps", "componentWillUpdate"].forEach(function(t3) {
    Object.defineProperty(C.prototype, t3, { configurable: true, get: function() {
      return this["UNSAFE_" + t3];
    }, set: function(n2) {
      Object.defineProperty(this, t3, { configurable: true, writable: true, value: n2 });
    } });
  });
  var en = l.event;
  l.event = function(n2) {
    return en && (n2 = en(n2)), n2.persist = function() {
    }, n2.isPropagationStopped = function() {
      return this.cancelBubble;
    }, n2.isDefaultPrevented = function() {
      return this.defaultPrevented;
    }, n2.nativeEvent = n2;
  };
  var rn;
  var un = { configurable: true, get: function() {
    return this.class;
  } };
  var on = l.vnode;
  l.vnode = function(n2) {
    "string" == typeof n2.type && (function(n3) {
      var t3 = n3.props, e3 = n3.type, u4 = {}, o4 = -1 == e3.indexOf("-");
      for (var i4 in t3) {
        var l4 = t3[i4];
        if (!("value" === i4 && "defaultValue" in t3 && null == l4 || Q2 && "children" === i4 && "noscript" === e3 || "class" === i4 || "className" === i4)) {
          var f4 = i4.toLowerCase();
          "defaultValue" === i4 && "value" in t3 && null == t3.value ? i4 = "value" : "download" === i4 && true === l4 ? l4 = "" : "translate" === f4 && "no" === l4 ? l4 = false : "o" === f4[0] && "n" === f4[1] ? "ondoubleclick" === f4 ? i4 = "ondblclick" : "onchange" !== f4 || "input" !== e3 && "textarea" !== e3 || X2(t3.type) ? "onfocus" === f4 ? i4 = "onfocusin" : "onblur" === f4 ? i4 = "onfocusout" : J2.test(i4) && (i4 = f4) : f4 = i4 = "oninput" : o4 && G2.test(i4) ? i4 = i4.replace(K2, "-$&").toLowerCase() : null === l4 && (l4 = void 0), "oninput" === f4 && u4[i4 = f4] && (i4 = "oninputCapture"), u4[i4] = l4;
        }
      }
      "select" == e3 && (u4.multiple && Array.isArray(u4.value) && (u4.value = F(t3.children).forEach(function(n4) {
        n4.props.selected = -1 != u4.value.indexOf(n4.props.value);
      })), null != u4.defaultValue && (u4.value = F(t3.children).forEach(function(n4) {
        n4.props.selected = u4.multiple ? -1 != u4.defaultValue.indexOf(n4.props.value) : u4.defaultValue == n4.props.value;
      }))), t3.class && !t3.className ? (u4.class = t3.class, Object.defineProperty(u4, "className", un)) : t3.className && (u4.class = u4.className = t3.className), n3.props = u4;
    })(n2), n2.$$typeof = q3, on && on(n2);
  };
  var ln = l.__r;
  l.__r = function(n2) {
    ln && ln(n2), rn = n2.__c;
  };
  var fn = l.diffed;
  l.diffed = function(n2) {
    fn && fn(n2);
    var t3 = n2.props, e3 = n2.__e;
    null != e3 && "textarea" === n2.type && "value" in t3 && t3.value !== e3.value && (e3.value = null == t3.value ? "" : t3.value), rn = null;
  };

  // node_modules/preact-render-to-string/dist/index.mjs
  var r3 = "diffed";
  var o3 = "__c";
  var i3 = "__s";
  var a3 = "__c";
  var c3 = "__k";
  var u3 = "__d";
  var s3 = "__s";
  var l3 = /[\s\n\\/='"\0<>]/;
  var f3 = /^(xlink|xmlns|xml)([A-Z])/;
  var p3 = /^(?:accessK|auto[A-Z]|cell|ch|col|cont|cross|dateT|encT|form[A-Z]|frame|hrefL|inputM|maxL|minL|noV|playsI|popoverT|readO|rowS|src[A-Z]|tabI|useM|item[A-Z])/;
  var h3 = /^ac|^ali|arabic|basel|cap|clipPath$|clipRule$|color|dominant|enable|fill|flood|font|glyph[^R]|horiz|image|letter|lighting|marker[^WUH]|overline|panose|pointe|paint|rendering|shape|stop|strikethrough|stroke|text[^L]|transform|underline|unicode|units|^v[^i]|^w|^xH/;
  var d3 = /* @__PURE__ */ new Set(["draggable", "spellcheck"]);
  function v3(e3) {
    void 0 !== e3.__g ? e3.__g |= 8 : e3[u3] = true;
  }
  function m3(e3) {
    void 0 !== e3.__g ? e3.__g &= -9 : e3[u3] = false;
  }
  function y3(e3) {
    return void 0 !== e3.__g ? !!(8 & e3.__g) : true === e3[u3];
  }
  var _3 = /["&<]/;
  function g4(e3) {
    if (0 === e3.length || false === _3.test(e3)) return e3;
    for (var t3 = 0, n2 = 0, r4 = "", o4 = ""; n2 < e3.length; n2++) {
      switch (e3.charCodeAt(n2)) {
        case 34:
          o4 = "&quot;";
          break;
        case 38:
          o4 = "&amp;";
          break;
        case 60:
          o4 = "&lt;";
          break;
        default:
          continue;
      }
      n2 !== t3 && (r4 += e3.slice(t3, n2)), r4 += o4, t3 = n2 + 1;
    }
    return n2 !== t3 && (r4 += e3.slice(t3, n2)), r4;
  }
  var b2 = {};
  var x3 = /* @__PURE__ */ new Set(["animation-iteration-count", "border-image-outset", "border-image-slice", "border-image-width", "box-flex", "box-flex-group", "box-ordinal-group", "column-count", "fill-opacity", "flex", "flex-grow", "flex-negative", "flex-order", "flex-positive", "flex-shrink", "flood-opacity", "font-weight", "grid-column", "grid-row", "line-clamp", "line-height", "opacity", "order", "orphans", "stop-opacity", "stroke-dasharray", "stroke-dashoffset", "stroke-miterlimit", "stroke-opacity", "stroke-width", "tab-size", "widows", "z-index", "zoom"]);
  var k3 = /[A-Z]/g;
  function w3(e3) {
    var t3 = "";
    for (var n2 in e3) {
      var r4 = e3[n2];
      if (null != r4 && "" !== r4) {
        var o4 = "-" == n2[0] ? n2 : b2[n2] || (b2[n2] = n2.replace(k3, "-$&").toLowerCase()), i4 = ";";
        "number" != typeof r4 || o4.startsWith("--") || x3.has(o4) || (i4 = "px;"), t3 = t3 + o4 + ":" + r4 + i4;
      }
    }
    return t3 || void 0;
  }
  function C3() {
    this.__d = true;
  }
  function A4(e3, t3) {
    return { __v: e3, context: t3, props: e3.props, setState: C3, forceUpdate: C3, __d: true, __h: new Array(0) };
  }
  var D3;
  var P4;
  var $2;
  var U3;
  var F3 = {};
  var M3 = [];
  var W3 = Array.isArray;
  var z3 = Object.assign;
  var H3 = "";
  var N3 = "<!--$s-->";
  var q4 = "<!--/$s-->";
  function B4(e3) {
    return "string" == typeof e3 ? N3 + e3 + q4 : W3(e3) ? (e3.unshift(N3), e3.push(q4), e3) : e3 && "function" == typeof e3.then ? e3.then(B4) : N3 + e3 + q4;
  }
  function I2(a4, u4, s4) {
    var l4 = l[i3];
    l[i3] = true, D3 = l.__b, P4 = l[r3], $2 = l.__r, U3 = l.unmount;
    var f4 = k(S, null);
    f4[c3] = [a4];
    try {
      var p4 = R2(a4, u4 || F3, false, void 0, f4, false, s4);
      return W3(p4) ? p4.join(H3) : p4;
    } catch (e3) {
      if (e3.then) throw new Error('Use "renderToStringAsync" for suspenseful rendering.');
      throw e3;
    } finally {
      l[o3] && l[o3](a4, M3), l[i3] = l4, M3.length = 0;
    }
  }
  function O3(e3, t3) {
    var n2, r4 = e3.type, o4 = true;
    return e3[a3] ? (o4 = false, (n2 = e3[a3]).state = n2[s3]) : n2 = new r4(e3.props, t3), e3[a3] = n2, n2.__v = e3, n2.props = e3.props, n2.context = t3, v3(n2), null == n2.state && (n2.state = F3), null == n2[s3] && (n2[s3] = n2.state), r4.getDerivedStateFromProps ? n2.state = z3({}, n2.state, r4.getDerivedStateFromProps(n2.props, n2.state)) : o4 && n2.componentWillMount ? (n2.componentWillMount(), n2.state = n2[s3] !== n2.state ? n2[s3] : n2.state) : !o4 && n2.componentWillUpdate && n2.componentWillUpdate(), $2 && $2(e3), n2.render(n2.props, n2.state, t3);
  }
  function R2(t3, r4, o4, i4, u4, _4, b3) {
    if (null == t3 || true === t3 || false === t3 || t3 === H3) return H3;
    var x4 = typeof t3;
    if ("object" != x4) return "function" == x4 ? H3 : "string" == x4 ? g4(t3) : t3 + H3;
    if (W3(t3)) {
      var k4, C4 = H3;
      u4[c3] = t3;
      for (var S2 = t3.length, L2 = 0; L2 < S2; L2++) {
        var E3 = t3[L2];
        if (null != E3 && "boolean" != typeof E3) {
          var j4, T4 = R2(E3, r4, o4, i4, u4, _4, b3);
          "string" == typeof T4 ? C4 += T4 : (k4 || (k4 = new Array(S2)), C4 && k4.push(C4), C4 = H3, W3(T4) ? (j4 = k4).push.apply(j4, T4) : k4.push(T4));
        }
      }
      return k4 ? (C4 && k4.push(C4), k4) : C4;
    }
    if (void 0 !== t3.constructor) return H3;
    t3.__ = u4, D3 && D3(t3);
    var Z = t3.type, M4 = t3.props;
    if ("function" == typeof Z) {
      var N4, q5, I3, K4 = r4;
      if (Z === S) {
        if ("tpl" in M4) {
          for (var G3 = H3, Q3 = 0; Q3 < M4.tpl.length; Q3++) if (G3 += M4.tpl[Q3], M4.exprs && Q3 < M4.exprs.length) {
            var X3 = M4.exprs[Q3];
            if (null == X3) continue;
            "object" != typeof X3 || void 0 !== X3.constructor && !W3(X3) ? G3 += X3 : G3 += R2(X3, r4, o4, i4, t3, _4, b3);
          }
          return G3;
        }
        if ("UNSTABLE_comment" in M4) return "<!--" + g4(M4.UNSTABLE_comment) + "-->";
        q5 = M4.children;
      } else {
        if (null != (N4 = Z.contextType)) {
          var Y = r4[N4.__c];
          K4 = Y ? Y.props.value : N4.__;
        }
        var ee = Z.prototype && "function" == typeof Z.prototype.render;
        if (ee) q5 = /**#__NOINLINE__**/
        O3(t3, K4), I3 = t3[a3];
        else {
          t3[a3] = I3 = /**#__NOINLINE__**/
          A4(t3, K4);
          for (var te = 0; y3(I3) && te++ < 25; ) {
            m3(I3), $2 && $2(t3);
            try {
              q5 = Z.call(I3, M4, K4);
            } catch (e3) {
              throw _4 && e3 && "function" == typeof e3.then && (t3._suspended = true), e3;
            }
          }
          v3(I3);
        }
        if (null != I3.getChildContext && (r4 = z3({}, r4, I3.getChildContext())), ee && l.errorBoundaries && (Z.getDerivedStateFromError || I3.componentDidCatch)) {
          q5 = null != q5 && q5.type === S && null == q5.key && null == q5.props.tpl ? q5.props.children : q5;
          try {
            return R2(q5, r4, o4, i4, t3, _4, false);
          } catch (e3) {
            return Z.getDerivedStateFromError && (I3[s3] = Z.getDerivedStateFromError(e3)), I3.componentDidCatch && I3.componentDidCatch(e3, F3), y3(I3) ? (q5 = O3(t3, r4), null != (I3 = t3[a3]).getChildContext && (r4 = z3({}, r4, I3.getChildContext())), R2(q5 = null != q5 && q5.type === S && null == q5.key && null == q5.props.tpl ? q5.props.children : q5, r4, o4, i4, t3, _4, b3)) : H3;
          } finally {
            P4 && P4(t3), U3 && U3(t3);
          }
        }
      }
      q5 = null != q5 && q5.type === S && null == q5.key && null == q5.props.tpl ? q5.props.children : q5;
      try {
        var ne = R2(q5, r4, o4, i4, t3, _4, b3);
        return P4 && P4(t3), l.unmount && l.unmount(t3), t3._suspended ? B4(ne) : ne;
      } catch (n2) {
        if (!_4 && b3 && b3.onError) {
          var re = (function e3(n3) {
            return b3.onError(n3, t3, function(t4, n4) {
              try {
                return R2(t4, r4, o4, i4, n4, _4, b3);
              } catch (t5) {
                return e3(t5);
              }
            });
          })(n2);
          if (void 0 !== re) return re;
          var oe = l.__e;
          return oe && oe(n2, t3), H3;
        }
        if (!_4) throw n2;
        if (!n2 || "function" != typeof n2.then) throw n2;
        return n2.then(function e3() {
          try {
            var n3 = R2(q5, r4, o4, i4, t3, _4, b3);
            return t3._suspended ? B4(n3) : n3;
          } catch (t4) {
            if (!t4 || "function" != typeof t4.then) throw t4;
            return t4.then(e3);
          }
        });
      }
    }
    var ie, ae = "<" + Z, ce = H3;
    for (var ue in M4) {
      var se = M4[ue];
      if ("function" != typeof (se = J3(se) ? se.value : se) || "class" === ue || "className" === ue) {
        switch (ue) {
          case "children":
            ie = se;
            continue;
          case "key":
          case "ref":
          case "__self":
          case "__source":
            continue;
          case "htmlFor":
            if ("for" in M4) continue;
            ue = "for";
            break;
          case "className":
            if ("class" in M4) continue;
            ue = "class";
            break;
          case "defaultChecked":
            ue = "checked";
            break;
          case "defaultSelected":
            ue = "selected";
            break;
          case "defaultValue":
          case "value":
            switch (ue = "value", Z) {
              case "textarea":
                ie = se;
                continue;
              case "select":
                i4 = se;
                continue;
              case "option":
                i4 != se || "selected" in M4 || (ae += " selected");
            }
            break;
          case "dangerouslySetInnerHTML":
            ce = se && se.__html;
            continue;
          case "style":
            "object" == typeof se && (se = w3(se));
            break;
          case "acceptCharset":
            ue = "accept-charset";
            break;
          case "httpEquiv":
            ue = "http-equiv";
            break;
          default:
            if (l3.test(ue)) continue;
            f3.test(ue) ? ue = ue.replace(f3, "$1:$2").toLowerCase() : "-" !== ue[4] && !d3.has(ue) || null == se ? o4 ? h3.test(ue) && (ue = "panose1" === ue ? "panose-1" : ue.replace(/([A-Z])/g, "-$1").toLowerCase()) : p3.test(ue) && (ue = ue.toLowerCase()) : se += H3;
        }
        null != se && false !== se && (ae = true === se || se === H3 ? ae + " " + ue : ae + " " + ue + '="' + ("string" == typeof se ? g4(se) : se + H3) + '"');
      }
    }
    if (l3.test(Z)) throw new Error(Z + " is not a valid HTML tag name in " + ae + ">");
    if (ce || ("string" == typeof ie ? ce = g4(ie) : null != ie && false !== ie && true !== ie && (ce = R2(ie, r4, "svg" === Z || "foreignObject" !== Z && o4, i4, t3, _4, b3))), P4 && P4(t3), U3 && U3(t3), !ce && V3.has(Z)) return ae + "/>";
    var le = "</" + Z + ">", fe = ae + ">";
    return W3(ce) ? [fe].concat(ce, [le]) : "string" != typeof ce ? [fe, ce, le] : fe + ce + le;
  }
  var V3 = /* @__PURE__ */ new Set(["area", "base", "br", "col", "command", "embed", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr"]);
  var K3 = I2;
  function J3(e3) {
    return null !== e3 && "object" == typeof e3 && "function" == typeof e3.peek && "value" in e3;
  }

  // entry2.js
  var ThemeCtx = X("light");
  var Row = N2(function Row2(props) {
    var label = T2(function() {
      return props.name.toUpperCase();
    }, [props.name]);
    var theme = x2(ThemeCtx);
    return k(
      "tr",
      { class: "row", "data-theme": theme },
      k("td", { style: { fontWeight: "bold", color: props.n > 1 ? "red" : "green" } }, label),
      k("td", { "aria-label": "value", hidden: props.n === 0 }, props.n)
    );
  });
  function Counter(props) {
    var s4 = d2(props.start);
    var count = s4[0];
    var r4 = y2(function(acc, x4) {
      return acc + x4;
    }, 100);
    return k("div", { class: "counter" }, [
      "count=" + count,
      " sum=" + r4[0],
      props.show === false ? null : k("em", null, " shown"),
      k("span", { dangerouslySetInnerHTML: { __html: "<b>raw&amp;</b>" } })
    ]);
  }
  function Table(props) {
    return k(
      ThemeCtx.Provider,
      { value: "dark" },
      k(
        S,
        null,
        k(Counter, { start: 7, show: true }),
        k(
          "table",
          null,
          k(
            "tbody",
            null,
            props.rows.map(function(r4, i4) {
              return k(Row, { key: "row-" + i4, name: r4.name, n: r4.n });
            })
          )
        ),
        null,
        false,
        0,
        void 0
      )
    );
  }
  var html = K3(k(Table, { rows: [{ name: "one", n: 0 }, { name: "two", n: 2 }, { name: "three", n: 5 }] }));
  print("PREACT_OK[" + html + "]");
})();
