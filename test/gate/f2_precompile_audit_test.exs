defmodule TinyLasers.Gate.F2PrecompileAuditTest do
  @moduledoc """
  **The PRE-COMPILE confinement window (`TinyLasers.Gate.audit_quoted/1`).**

  `dangerous_refs/1` inspects the emitted bytecode — but `Code.compile_quoted` expands macros and evaluates the
  module body BEFORE that bytecode exists. This is the compile-time-execution window the output check cannot
  see (the class of bug in wb-10lz: RCE during compilation, before any authorship/output gate). `audit_quoted`
  closes it by proving the lowered guest module contains only inert, whitelisted shapes.

  This test proves: (1) every real lowered program passes the audit; (2) the audit REJECTS each compile-time
  execution vector; (3) a live canary shows one vector actually executes at compile time when compiled directly
  — and that the gate blocks it before the compiler runs.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Gate
  alias TinyLasers.Gate.{Js, Lower}

  defp lowered_module(src) do
    body = Lower.program(Js.parse(src), %{"print" => 0})
    modname = Module.concat([TinyLasers.Gate.Guest, "Audit#{System.unique_integer([:positive])}"])
    quote do
      defmodule unquote(modname) do
        def run, do: unquote(body)
      end
    end
  end

  @real [
    ~S'var x = 1; for (var i=0;i<3;i++){ x += i; } print(x);',
    ~S'function f(a){ return a*2; } class C { constructor(){ this.v = 1; } get w(){ return this.v; } set w(n){ this.v = n; } } var c = new C(); c.w = f(5); print(c.w);',
    ~S'try { throw new Error("e"); } catch(e){ print(e.message); } finally { print("done"); }',
    ~S'function* g(){ yield 1; yield* [2,3]; } var s = 0; for (const y of g()) s += y; print(s);',
    ~S'async function h(){ return await Promise.resolve(42); } h().then(function(v){ print(v); });',
    ~S'var [a, ...b] = [1,2,3]; var o = {...{p:1}, q:2}; var r = /ab+/gi; print(a + b.length + o.q + (r.test("abb")));',
    ~S'var big = 1n << 64n; print(typeof big); var t = `sum=${1+2}`; var m = null?.x ?? "d"; print(t + m);',
    ~S'switch(2){ case 1: print("one"); break; case 2: print("two"); break; default: print("d"); }',
    ~S'var arr = new Array(3); var i=0; for (const v of ["a","b","c"]) { arr[i++] = v; } print(arr.join(","));'
  ]

  test "every real lowered guest program passes the pre-compile audit" do
    for src <- @real do
      q = lowered_module(src)
      assert Gate.safe_to_compile?(q), "real program flagged unsafe: #{inspect(Gate.audit_quoted(q))}\n  src=#{src}"
    end
  end

  test "audit rejects a module-body statement that would run at compile time" do
    # a bare expression in the module body evaluates during Code.compile_quoted.
    q = quote do
      defmodule EvilBody do
        System.cmd("echo", ["pwned"])
        def run, do: :ok
      end
    end

    refute Gate.safe_to_compile?(q)
    assert Gate.audit_quoted(q).modbody_nondef != []
  end

  test "audit rejects a module attribute (compile-time evaluated)" do
    q = quote do
      defmodule EvilAttr do
        @pwn File.read!("/etc/passwd")
        def run, do: :ok
      end
    end

    refute Gate.safe_to_compile?(q)
    assert Gate.audit_quoted(q).attrs != []
  end

  test "audit rejects a non-Runtime remote call in a function body" do
    q = quote do
      defmodule EvilRemote do
        def run, do: System.cmd("rm", ["-rf", "/"])
      end
    end

    refute Gate.safe_to_compile?(q)
    assert {System, :cmd} in Gate.audit_quoted(q).bad_remote
  end

  test "audit rejects a code-executing local macro head (outside the safe set)" do
    # `apply/3` and `spawn/1` as bare local calls are not in the safe Kernel-form whitelist.
    q = quote do
      defmodule EvilLocal do
        def run, do: apply(System, :halt, [0])
      end
    end

    refute Gate.safe_to_compile?(q)
    assert :apply in Gate.audit_quoted(q).bad_local
  end

  test "CANARY: a real compile-time-execution vector fires when compiled directly, and the gate blocks it first" do
    key = {:f2_gate_canary, System.unique_integer([:positive])}
    :persistent_term.erase(key)

    # a module attribute whose value has a side effect: evaluated at COMPILE time by Code.compile_quoted.
    evil = quote do
      defmodule unquote(Module.concat([TinyLasers.Gate.Guest, "Canary#{System.unique_integer([:positive])}"])) do
        @canary :persistent_term.put(unquote(Macro.escape(key)), :FIRED)
        def run, do: :ok
      end
    end

    # 1) the gate REJECTS it before the compiler ever runs.
    refute Gate.safe_to_compile?(evil)
    assert_raise ArgumentError, fn -> Gate.assert_safe_to_compile!(evil) end
    assert :persistent_term.get(key, :unset) == :unset, "gate must block BEFORE any compile-time effect"

    # 2) prove the vector is REAL: compiling the same AST directly (no gate) fires the canary at compile time.
    Code.compile_quoted(evil)
    assert :persistent_term.get(key, :unset) == :FIRED, "the attribute vector should execute at compile time"

    :persistent_term.erase(key)
  end
end
