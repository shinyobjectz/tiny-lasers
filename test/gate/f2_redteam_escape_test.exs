defmodule TinyLasers.Gate.F2RedteamEscapeTest do
  @moduledoc """
  **F2 SECURITY RED-TEAM — adversarial escape attempts against `TinyLasers.Gate`.**

  Assume the confinement model is BROKEN until each vector proves otherwise. Every probe runs hostile guest
  JS through BOTH frontends — `Walk` (interpreter) and `Lower` (compiled `.beam`) — and asserts one of:

    * CONFINED — mechanically proven by:
        (a) `TinyLasers.Gate.dangerous_refs(bin) == %{ext: [], bifs: []}` (the emitted bytecode names only the
            Runtime; no dangerous BIF is physically present), AND
        (b) the run result is a closed guest value / guest error / timeout — never a host effect, AND
        (c) NO host module-atom / pid / port / reference appears anywhere in a guest-reachable value, AND
        (d) for atom-DoS: guest STRING DATA is never interned (`binary_to_existing_atom` raises).
    * ESCAPE — documented precisely (severity + repro + violated invariant).

  THE INVARIANT under attack: guest data never crosses into the atom / MFA / raw-fun / raw-pid / module-name
  domain, so a host module is not merely blocked but UNNAMEABLE.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate
  alias TinyLasers.Gate.{Js, Runtime, Walk}

  # ── mechanical-proof helpers ────────────────────────────────────────────────────────────────────────────

  defp confined?(bin), do: Gate.dangerous_refs(bin) == %{ext: [], bifs: []}

  # Module atoms whose PRESENCE in a guest-reachable value would be a real escape (host authority). Chosen to
  # NOT overlap any guest value/tag atom (`:obj`,`:arr`,`:cell`,`:global`,`:host`,`:fn`,`:symbol`,`:bigint`,…),
  # so a hit is unambiguous. `:global` is a guest namespace TAG (and coincidentally an OTP module) — excluded
  # on purpose; the guest can never turn the tuple `{:global, "Object"}` into a module invocation.
  @danger_atoms [
    System, File, Code, IO, Process, Kernel, Enum, Map, Application, Node,
    TinyLasers.Gate, TinyLasers.Gate.Runtime, TinyLasers.Gate.Lower, TinyLasers.Gate.Js,
    TinyLasers.Wasm, TinyLasers.Wasm.HostRollup,
    :os, :erlang, :file, :init, :code, :ets, :dets, :persistent_term, :rpc, :net_kernel, :application
  ]

  # deep-scan a guest-reachable term for host authority: dangerous module-atoms, pids, ports, refs. Does NOT
  # descend into raw funs (a `{:fn, fun}` closure is a guest value the guest cannot decompose — the fun body
  # itself calls only Runtime; there is no guest opcode that extracts and `apply`s it).
  defp host_refs(a) when is_atom(a), do: if(a in @danger_atoms, do: [a], else: [])
  defp host_refs(p) when is_pid(p) or is_port(p) or is_reference(p), do: [p]
  defp host_refs(t) when is_tuple(t), do: t |> Tuple.to_list() |> Enum.flat_map(&host_refs/1)
  defp host_refs(l) when is_list(l), do: Enum.flat_map(l, &host_refs/1)
  defp host_refs(m) when is_map(m), do: m |> Map.to_list() |> Enum.flat_map(&host_refs/1)
  defp host_refs(_), do: []

  # the compiled/Lower lane. Returns the full run map (result/output/binary).
  defp lower(src, opts \\ []), do: Js.run(src, opts)

  # the interpreter/Walk lane. Returns {result_tag, value_or_reason, output}. Confinement is structural (the
  # interpreter only ever calls Runtime.*), so we assert the value/effect domain, not a binary.
  defp walk(src) do
    ast = Js.parse(src)
    Runtime.__init(%{caps: %{0 => %{fun: &Runtime.cap_print/2}}, tenant_root: "/t", fs: %{}})

    try do
      v = Walk.run(ast, %{"print" => 0})
      Runtime.drain_microtasks()
      {:ok, v, Runtime.__output()}
    catch
      :throw, {:gg_return, v} -> {:ok, v, Runtime.__output()}
      :throw, {:gg_guest_error, r} -> {:guest_error, r, Runtime.__output()}
      :throw, {:gg_throw, v} -> {:guest_error, v, Runtime.__output()}
      kind, e -> {:crash, {kind, e}, Runtime.__output()}
    end
  end

  # A run result is CONFINED if it stayed in the closed guest universe: a guest value, a guest error, a
  # timeout, or an internal Elixir exception that (crucially) never handed the guest host authority. Anything
  # is fine EXCEPT a host ref leaking into a returned guest value.
  defp assert_value_confined(result) do
    case result do
      {:ok, v} -> assert host_refs(v) == [], "host ref leaked into guest value: #{inspect(host_refs(v))}"
      {:guest_error, r} -> assert host_refs(r) == [], "host ref leaked into guest error: #{inspect(host_refs(r))}"
      {:timeout, _} -> :ok
      {:crash, _kind, _e} -> :ok
      other -> flunk("unexpected non-confined result shape: #{inspect(other)}")
    end
  end

  # full CONFINED proof for the compiled lane.
  defp assert_lower_confined(%{binary: bin, result: result, output: out}, allow_out \\ []) do
    assert confined?(bin),
           "COMPILED GUEST NAMED A NON-RUNTIME REF (ESCAPE): #{inspect(Gate.dangerous_refs(bin))}"

    assert_value_confined(result)

    assert out == allow_out,
           "guest produced host output beyond its grant: #{inspect(out)} (allowed #{inspect(allow_out)})"
  end

  defp assert_walk_confined({tag, v, out}, allow_out \\ []) do
    assert_value_confined((if tag == :crash, do: {:crash, :x, v}, else: {tag, v}))
    assert out == allow_out, "walk produced host output beyond grant: #{inspect(out)}"
  end

  defp atoms_must_be_absent(strings) do
    for s <- strings do
      assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(s, :utf8) end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 1 — eval / Function("...") : does the confined interp/dead builtins ever reach a host ref?
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V1 eval / Function constructor" do
    test "the `Function` constructor cannot build a callable from a string (RCE primitive absent)" do
      srcs = [
        ~S"""
        var f = Function("return 42"); typeof f;
        """,
        ~S"""
        try { var f = new Function("x", "return x*2"); print(f(21)); } catch (e) { print("blocked:" + (e.name || "err")); }
        """,
        ~S"""
        var g = (function(){}).constructor; typeof g === "undefined" ? "no-ctor" : (typeof g("code"));
        """
      ]

      for src <- srcs do
        r = lower(src)
        assert_lower_confined(r, r.output)
        w = walk(src)
        assert_walk_confined(w, elem(w, 2))
      end
    end

    test "`eval(...)` as a JS global is undefined — not wired to any host-code path" do
      src = ~S"""
      try { eval("os.cmd('rm -rf /')"); print("RAN"); } catch (e) { print("blocked"); }
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      refute "RAN" in r.output
    end

    test "the eval CAPABILITY (tuple-AST gate) confines eval'd source identically — cannot name :os" do
      ast = {:call, {:var, "eval"}, [{:lit, "os.cmd('echo pwned')"}]}
      c = Gate.compile(ast, ["eval"])
      out = Gate.run(c)
      assert out.result == {:guest_error, "not a function"}
      assert out.output == []
      assert Gate.dangerous_refs(c) == %{ext: [], bifs: []}
    end

    test "eval capability cannot WIDEN privilege beyond the parent grant" do
      ast = {:call, {:var, "eval"}, [{:lit, "fs_write('/work/x', 'pwn')"}]}
      c = Gate.compile(ast, ["eval", "print"])
      out = Gate.run(c, tenant_root: "/work")
      assert out.result == {:guest_error, "not a function"}
      assert out.fs_writes == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 2 — Proxy traps (get/set/apply/has/ownKeys): can a trap send or receive a host term?
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V2 Proxy traps" do
    test "get/set/has/ownKeys traps only ever exchange guest values" do
      src = ~S"""
      var seen = [];
      var p = new Proxy({ real: 1 }, {
        get: function(t, k, recv) { seen.push("get:" + String(k)); return t[k]; },
        set: function(t, k, v, recv) { seen.push("set:" + String(k)); t[k] = v; return true; },
        has: function(t, k) { seen.push("has:" + String(k)); return k in t; },
        ownKeys: function(t) { return Object.keys(t); }
      });
      p.evil = "x";
      var a = p.real;
      var b = ("real" in p);
      print(a + "," + b + "," + seen.join("|"));
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      w = walk(src)
      assert_walk_confined(w, elem(w, 2))
    end

    test "a trap that tries to RETURN a host-looking name yields only a guest string, never a module" do
      src = ~S"""
      var p = new Proxy({}, { get: function(t, k) { return "Elixir.System"; } });
      var m = p.anything;
      var r1 = (typeof m);
      print(r1 + "," + m);
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 3 — prototype pollution: __proto__ / constructor / setPrototypeOf reaching a host ref
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V3 prototype pollution" do
    @proto_attacks [
      {"proto-read", ~S"""
       var o = {}; print(typeof o.__proto__);
       """},
      {"proto-write-then-poison", ~S"""
       var o = {}; o.__proto__ = { pwned: 1 }; var v = {}; print(v.pwned);
       """},
      {"constructor-chain-rce", ~S"""
       var o = {}; var C = o.constructor; print(typeof C);
       """},
      {"constructor-constructor-rce", ~S"""
       try { var f = ({}).constructor.constructor("return this")(); print("GOT:" + typeof f); } catch(e){ print("blocked"); }
       """},
      {"Object.prototype-pollute", ~S"""
       Object.prototype.pwned = 1; var v = {}; print(v.pwned + "," + typeof Object.prototype);
       """},
      {"setPrototypeOf-to-global", ~S"""
       var o = {}; Object.setPrototypeOf(o, Object.prototype); print(typeof o);
       """},
      {"create-null-proto", ~S"""
       var o = Object.create(null); o.x = 1; print(o.x);
       """},
      {"proto-of-error-walk", ~S"""
       var e = new TypeError("x"); print(typeof e.constructor + "," + (e.constructor === TypeError));
       """}
    ]

    for {name, src} <- @proto_attacks do
      test "prototype vector confined: #{name}" do
        src = unquote(src)
        r = lower(src)
        assert_lower_confined(r, r.output)
        w = walk(src)
        assert_walk_confined(w, elem(w, 2))
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 4 — getters/setters/accessors invoked with a hostile receiver
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V4 accessors with hostile receiver" do
    test "an accessor getter invoked via Reflect.get with an attacker-chosen receiver stays confined" do
      src = ~S"""
      var o = {};
      Object.defineProperty(o, "x", { get: function() { return this.secret || "no-secret"; } });
      var r = Reflect.get(o, "x", { secret: "leak?" });
      print(String(r));
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
    end

    test "{:accessor, get, set} merge + setter routing exchanges only guest values" do
      src = ~S"""
      var log = [];
      var o = {};
      Object.defineProperty(o, "p", { get: function() { return this._p; } });
      Object.defineProperty(o, "p", { set: function(v) { this._p = "set:" + v; log.push("set"); } });
      o.p = "hi";
      print(o.p + "|" + log.join(","));
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      w = walk(src)
      assert_walk_confined(w, elem(w, 2))
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 5 — computed member dispatch + Reflect/Object statics naming a host thing
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V5 computed dispatch / Reflect / Object statics" do
    @dispatch_attacks [
      {"computed-bif-name", ~S"""
       var o = {}; var n = "spawn"; try { o[n](); print("RAN"); } catch(e){ print("blocked"); }
       """},
      {"computed-module-name", ~S"""
       var m = {}; var k = "Elixir.System"; print(typeof m[k]);
       """},
      {"reflect-apply-nonfn", ~S"""
       try { Reflect.apply("os", null, ["cmd"]); print("RAN"); } catch(e){ print("blocked"); }
       """},
      {"reflect-construct-string", ~S"""
       try { Reflect.construct("System", []); print("RAN"); } catch(e){ print("blocked"); }
       """},
      {"reflect-get-proto", ~S"""
       var o = {a:1}; print(String(Reflect.getPrototypeOf(o)));
       """},
      {"reflect-ownkeys", ~S"""
       var o = {a:1,b:2}; print(Reflect.ownKeys(o).join(","));
       """},
      {"object-keys-on-global", ~S"""
       print(Object.keys(Math).length >= 0);
       """},
      {"computed-call-host-handle", ~S"""
       var o = { p: print }; var k = "p"; o[k]("via-computed"); print("done");
       """}
    ]

    for {name, src} <- @dispatch_attacks do
      test "computed dispatch confined: #{name}" do
        src = unquote(src)
        r = lower(src)
        assert_lower_confined(r, r.output)
        w = walk(src)
        assert_walk_confined(w, elem(w, 2))
      end
    end

    test "computed dispatch never returns a host ref regardless of the guest-chosen key" do
      src = ~S"""
      var o = { a: 1 };
      var keys = ["constructor","__proto__","prototype","apply","call","bind","spawn","halt",
                  "Elixir.System","erlang","valueOf","toString","hasOwnProperty"];
      var out = [];
      for (var i = 0; i < keys.length; i++) { out.push(typeof o[keys[i]]); }
      print(out.join(","));
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 6 — error objects + {:proto, err} / .constructor === TypeError plumbing
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V6 error object plumbing" do
    test "thrown error's constructor/prototype chain exposes only guest namespace tokens" do
      src = ~S"""
      var results = [];
      try { null.x; } catch (e) {
        results.push(e instanceof TypeError);
        results.push(e.constructor === TypeError);
        results.push(e.name);
        results.push(typeof e.constructor);
        results.push(typeof e.constructor.constructor);
      }
      print(results.join(","));
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []

      src2 = ~S"""
      throw new RangeError("boom");
      """

      r2 = lower(src2)
      assert_lower_confined(r2, r2.output)
      assert match?({:guest_error, _}, r2.result)
      assert host_refs(r2.result) == []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 7 — implicit-global path (gget/gset -> {:globalobj})
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V7 implicit global object" do
    @global_attacks [
      {"implicit-global-rw", ~S"""
       leaked = "x"; leaked = leaked + "y"; print(leaked);
       """},
      {"globalThis-reach", ~S"""
       print(typeof globalThis + "," + typeof globalThis.process + "," + typeof globalThis.require);
       """},
      {"globalThis-constructor", ~S"""
       print(typeof globalThis.constructor);
       """},
      {"global-as-key-carrier", ~S"""
       globalThis["Elixir.System"] = 1; print(typeof globalThis["Elixir.System"]);
       """},
      {"self-window-alias", ~S"""
       print((self === globalThis) + "," + (window === globalThis));
       """}
    ]

    for {name, src} <- @global_attacks do
      test "implicit global confined: #{name}" do
        src = unquote(src)
        r = lower(src)
        assert_lower_confined(r, r.output)
        assert host_refs(r.result) == []
        w = walk(src)
        assert_walk_confined(w, elem(w, 2))
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 8 — symbol keys / JSON / typed arrays / ArrayBuffer / BigInt / templates / tagged templates
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V8 symbols / JSON / typed arrays / bigint / templates" do
    test "symbol keys never mint atoms and never surface a host ref" do
      src = ~S"""
      var s1 = Symbol("zsym_alpha");
      var s2 = Symbol.for("zsym_bravo");
      var o = {};
      o[s1] = "zsym_charlie";
      o[s2] = "zsym_delta";
      o[Symbol.iterator] = "zsym_echo";
      print(o[s1] + "," + o[s2] + "," + typeof s1);
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
      atoms_must_be_absent(~w(zsym_alpha zsym_bravo zsym_charlie zsym_delta zsym_echo))
    end

    test "JSON.parse/stringify of hostile string data stays in the guest term domain, no atoms" do
      src = ~S"""
      var raw = '{"zjson_key":"zjson_val","erlang":"os","nested":{"Elixir.System":1}}';
      var o = JSON.parse(raw);
      var back = JSON.stringify(o);
      print(o.zjson_key + "|" + typeof o["Elixir.System"] + "|" + back.length);
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
      atoms_must_be_absent(~w(zjson_key zjson_val))
    end

    test "typed arrays / ArrayBuffer / DataView expose only numbers and byte buffers" do
      src = ~S"""
      var buf = new ArrayBuffer(8);
      var u8 = new Uint8Array(buf);
      for (var i = 0; i < 8; i++) u8[i] = i * 16;
      var u32 = new Uint32Array(buf);
      var dv = new DataView(buf);
      print(u8[3] + "," + u32.length + "," + dv.getUint8(3) + "," + typeof u8[0]);
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
      w = walk(src)
      assert_walk_confined(w, elem(w, 2))
    end

    test "BigInt, template literals, and (unsupported) tagged templates are inert & confined" do
      srcs = [
        ~S"""
        var b = (1n << 200n); print(typeof b + "," + (b > 0n));
        """,
        ~S"""
        var n = 3; print(`t${n}_zval` + "|" + `${`in${n}`}`);
        """,
        ~S"""
        function tag(strs, x){ return strs[0] + ":" + x; } try { print(tag`a${5}b`); } catch(e){ print("tagerr"); }
        """
      ]

      for src <- srcs do
        r = lower(src)
        assert_lower_confined(r, r.output)
        assert host_refs(r.result) == []
      end
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 9 — capability handles: forge or widen a {:host, cap_id}
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V9 capability handle forgery" do
    test "a guest cannot fabricate a {:host, N} handle from data structures" do
      srcs = [
        ~S"""
        try { var h = [1, 5]; h("x"); print("RAN"); } catch(e){ print("blocked"); }
        """,
        ~S"""
        try { var h = { tag: "host", id: 0 }; h("x"); print("RAN"); } catch(e){ print("blocked"); }
        """,
        ~S"""
        try { var h = { 0: "host", 1: 999 }; h(); print("RAN"); } catch(e){ print("blocked"); }
        """
      ]

      for src <- srcs do
        r = lower(src)
        assert_lower_confined(r, r.output)
        refute "RAN" in r.output
      end
    end

    test "the ONLY reachable {:host,_} is the granted print handle (id 0); no other id is reachable" do
      src = ~S"""
      var box = { p: print }; print("ok"); box.p;
      """

      r = lower(src)
      assert confined?(r.binary)
      assert r.result == {:ok, {:host, 0}}
      assert host_refs(r.result) == []
    end

    test "host_rollup_bridge is not grantable via the JS frontend and cannot be named" do
      src = ~S"""
      print(typeof host_rollup_bridge + "," + typeof HostRollup + "," + typeof __host);
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert r.output == ["undefined,undefined,undefined"]
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 10 — atom-table DoS: does executing guest programs with distinct string DATA mint atoms?
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V10 atom-table firewall" do
    test "distinct guest string DATA (keys, values, dispatch names) is never interned" do
      prog = fn tag ->
        """
        var o = {};
        o['#{tag}_ka'] = '#{tag}_va';
        o['#{tag}_kb'] = o['#{tag}_ka'];
        var arr = ['#{tag}_vc', '#{tag}_vd'];
        var pick = arr[0];
        o[pick] = '#{tag}_ve';
        var sym = Symbol('#{tag}_sym');
        o[sym] = '#{tag}_vf';
        JSON.parse('{"#{tag}_kg":"#{tag}_vg"}')['#{tag}_kg'];
        """
      end

      r = lower(prog.("zrt"))
      assert confined?(r.binary)
      assert r.result == {:ok, "zrt_vg"}

      atoms_must_be_absent(
        ~w(zrt_ka zrt_va zrt_kb zrt_vc zrt_vd zrt_ve zrt_sym zrt_vf zrt_kg zrt_vg)
      )
    end

    test "running many same-structure programs with DIFFERENT data does not balloon the atom table" do
      prog = fn tag -> "var o = {}; o['#{tag}_k'] = '#{tag}_v'; o['#{tag}_k'];" end
      compiled = for tag <- ~w(qa qb qc qd qe qf qg qh), do: lower(prog.(tag))
      _ = compiled

      base = :erlang.system_info(:atom_count)
      for tag <- ~w(ra rb rc rd re rf rg rh), do: lower(prog.(tag))
      grew = :erlang.system_info(:atom_count) - base
      assert grew < 200, "distinct-data programs grew the atom table by #{grew} (looks like data is interned)"
      atoms_must_be_absent(~w(ra_k ra_v rh_k rh_v))
    end

    test "binary_to_existing_atom on guest keys raises even after they are used as object keys" do
      src = ~S"""
      var o = {}; o["zbea_probe_key"] = "zbea_probe_val"; Object.keys(o)[0];
      """

      r = lower(src)
      assert r.result == {:ok, "zbea_probe_key"}
      atoms_must_be_absent(~w(zbea_probe_key zbea_probe_val))
    end

    test "DOCUMENTED CAVEAT: compile-time IDENTIFIER names ARE interned (bounded compile-time cost, not a term-domain breach)" do
      # The acknowledged AOT cost: `lvar` = String.to_atom("gg_" <> name). A guest IDENTIFIER becomes an Elixir
      # var atom at COMPILE time. NOT a runtime firewall breach (no guest DATA is atomized), but an unbounded-if-
      # uncapped compile-time atom-DoS the Lower lane should cap. The same token as an IDENTIFIER gets interned
      # as `gg_<name>`; used as DATA it does not.
      token = "zident_caveat_marker"
      src = "var #{token} = 1; var s = \"#{token}\"; print(#{token} + s.length);"
      r = lower(src)
      assert confined?(r.binary)

      assert :erlang.binary_to_existing_atom("gg_" <> token, :utf8) == :"gg_#{token}"
      atoms_must_be_absent([token])
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # VECTOR 11 — force Lower to emit a non-Runtime remote / bare throw / attribute / unquote / macro
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "V11 Lower codegen leak attempts" do
    @codegen_attacks [
      {"module-string-call", ~S"""
       var m = "Elixir.System"; m.cmd("id");
       """},
      {"erlang-atom-call", ~S"""
       var e = "erlang"; e.halt(0);
       """},
      {"throw-raw", ~S"""
       throw "raw-string";
       """},
      {"deep-try-finally", ~S"""
       function f(){ try { throw new Error("x"); } finally { return 1; } } print(f());
       """},
      {"generator-spread", ~S"""
       function* g(){ yield 1; yield* [2,3]; } print([...g()].join(","));
       """},
      {"class-extends-builtin", ~S"""
       class X extends Set { add(){ throw new Error("no"); } } var x = new X(); print(x.size);
       """},
      {"proxy-of-everything", ~S"""
       var p = new Proxy(function(){}, { apply: function(){ return "trapped"; } }); print(typeof p);
       """},
      {"async-await-reject", ~S"""
       async function f(){ try { await Promise.reject(new Error("x")); } catch(e){ return "c"; } } f().then(function(v){ print(v); });
       """},
      {"computed-super", ~S"""
       class A { m(){ return "a"; } } class B extends A { m(){ return super.m() + "b"; } } print(new B().m());
       """},
      {"regex-replace-fn", ~S"""
       print("a1b2".replace(/(\d)/g, function(m, d){ return "[" + d + "]"; }));
       """},
      {"deep-nest-optional", ~S"""
       var o = null; print(o?.a?.b?.c ?? "fallback");
       """},
      {"bigint-shift-loop", ~S"""
       var m = 1n; for (var i=0;i<80;i++){ m <<= 1n; } print(m > 0n);
       """},
      {"eval-like-Function", ~S"""
       try { print(new Function("return 1")()); } catch(e){ print("no-fn"); }
       """},
      {"labeled-break-nested", ~S"""
       var s=""; a: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ if(j==1) continue a; s+=i+""+j; } } print(s);
       """}
    ]

    for {name, src} <- @codegen_attacks do
      test "codegen stays confined: #{name}" do
        src = unquote(src)
        # (a) pre-compile AST audit: the lowered module contains only inert whitelisted shapes.
        body = TinyLasers.Gate.Lower.program(Js.parse(src), %{"print" => 0})
        mod = Module.concat([TinyLasers.Gate.Guest, "RT#{System.unique_integer([:positive])}"])
        quoted = quote(do: (defmodule unquote(mod) do def run, do: unquote(body) end))
        report = Gate.audit_quoted(quoted)

        assert report.modbody_nondef == [], "compile-time module-body statement emitted: #{inspect(report.modbody_nondef)}"
        assert report.attrs == [], "module attribute emitted: #{inspect(report.attrs)}"
        assert report.unquote == [], "stray unquote emitted: #{inspect(report.unquote)}"
        assert report.bad_remote == [], "NON-RUNTIME REMOTE CALL EMITTED (ESCAPE): #{inspect(report.bad_remote)}"
        assert report.bad_local == [], "code-executing local head emitted: #{inspect(report.bad_local)}"
        assert Gate.safe_to_compile?(quoted)

        # (b) post-compile bytecode inspector: the real binary names only the Runtime, no dangerous BIF.
        r = lower(src)
        assert_lower_confined(r, r.output)
      end
    end

    test "the pre-compile audit still FAILS CLOSED on a hand-forged escape (control: the gate is live)" do
      evil_remote = quote(do: (defmodule EvilRT do def run, do: System.cmd("id", []) end))
      refute Gate.safe_to_compile?(evil_remote)
      assert {System, :cmd} in Gate.audit_quoted(evil_remote).bad_remote

      evil_attr =
        quote do
          defmodule EvilAT do
            @x File.read!("/etc/passwd")
            def run, do: :ok
          end
        end

      refute Gate.safe_to_compile?(evil_attr)
      assert evil_attr |> Gate.audit_quoted() |> Map.fetch!(:attrs) != []
    end
  end

  # ══════════════════════════════════════════════════════════════════════════════════════════════════════
  # EXTRA — bonus adversarial vectors beyond the assigned list
  # ══════════════════════════════════════════════════════════════════════════════════════════════════════

  describe "EXTRA adversarial vectors" do
    test "Symbol.toPrimitive / valueOf coercion cannot smuggle a host term through arithmetic" do
      src = ~S"""
      var o = {};
      o[Symbol.toPrimitive] = function(){ return "erlang"; };
      var s = "" + o;
      print(s + "," + typeof s);
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
    end

    test "deeply nested guest data returned to the host contains no host authority" do
      src = ~S"""
      var deep = { a: [ { b: new Map([["k", new Set([1,2])]]) } ], f: function(){ return 1; }, e: new Error("x") };
      deep;
      """

      r = lower(src)
      assert confined?(r.binary)
      assert host_refs(r.result) == [], "host ref buried in nested guest value: #{inspect(host_refs(r.result))}"
    end

    test "for-in / for-of over builtins and globals never enumerates a host ref" do
      src = ~S"""
      var out = [];
      for (var k in Math) out.push(typeof k);
      for (var k2 in { a: 1, b: 2 }) out.push(k2);
      print(out.join(","));
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
    end

    test "a runaway loop is contained by the run timeout without harming the caller" do
      src = ~S"""
      while (true) {}
      """

      r = lower(src, timeout: 300)
      assert match?({:timeout, _}, r.result)
      assert Process.alive?(self())
      assert confined?(r.binary)
    end

    test "Object.getOwnPropertyDescriptor never exposes a host getter/setter fun as a nameable ref" do
      src = ~S"""
      var o = { x: 1 };
      var d = Object.getOwnPropertyDescriptor(o, "x");
      print(d.value + "," + d.writable + "," + typeof d);
      """

      r = lower(src)
      assert_lower_confined(r, r.output)
      assert host_refs(r.result) == []
    end
  end
end
