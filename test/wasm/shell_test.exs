defmodule TinyLasers.WasmShellTest do
  @moduledoc """
  **"bash in WASM" runs on tiny-lasers — the emulation thesis as a runnable artifact.**

  `priv/shell/sh.c` is the *washy* shell: a no-fork shell compiled to a `wasm32-wasip1` command module.
  The only thing a real shell needs `fork`/`exec` for is pipes between processes — here a pipeline is
  BUFFERED CHAINING in one process (run a stage to completion, feed its output to the next). Builtins are
  compiled in (echo/grep/rev/upper/lower/true/false); files go over the `/work` preopen, which lands on
  `TinyLasers.Wasm.VFS` — a BEAM-resident virtual filesystem. So pipes = in-memory buffering, fs = VFS,
  exec = builtins (non-builtins delegate to `host_exec`, the real-coreutils path, not wired in this lean
  substrate). It runs IDENTICALLY in the interpreter and the asm/transpile lane (interp ≡ asm).

  Rebuild the fixture: `sh tools/build_shell.sh` (compiles priv/shell/sh.c via the vendored wasi-sdk).
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @fixture Path.join(__DIR__, "../conformance/shell/washy_sh.wasm")

  setup do
    {:ok, mod} = Wasm.decode(File.read!(@fixture))
    {:ok, mod: mod}
  end

  # Run `sh "<cmd>"` and return captured stdout. A WASI command exits via proc_exit (thrown {:tl_exit,_});
  # stdout was already flushed to :tl_out, so read it back on that path.
  defp sh(mod, cmd, transpile?) do
    Process.put(:tl_argv, ["sh", cmd])
    Process.put(:tl_stdin, "")

    try do
      {_res, out} = Wasm.call_io(mod, "_start", [], transpile: transpile?)
      out
    catch
      :throw, {:tl_exit, _code} -> Process.get(:tl_out) |> List.wrap() |> IO.iodata_to_binary()
    end
  end

  test "it really is a wasm32-wasip1 command module backed by our WASI surface", %{mod: mod} do
    names = MapSet.new(mod.imports, fn {_m, n, _t} -> n end)
    assert "fd_write" in names and "fd_read" in names and "path_open" in names
    assert "args_get" in names, "the shell reads its command line from argv (args_get → :tl_argv)"
    assert "proc_exit" in names
  end

  # Each command must produce the exact bytes, AND the asm lane must agree with the interpreter.
  @commands [
    {"echo a builtin", "echo hello world", "hello world\n"},
    {"a fork-less pipe (echo | upper)", "echo hello | upper", "HELLO\n"},
    {"lower builtin", "echo HELLO | lower", "hello\n"},
    {"rev builtin", "echo abc | rev", "cba\n"},
    {"grep builtin filters", "echo hello world | grep world", "hello world\n"},
    {"a 3-stage pipeline", "echo a | upper | lower", "a\n"},
    {"a for loop (shell grammar)", "for x in a b c; do echo $x; done", "a\nb\nc\n"},
    {"an if/else (shell grammar)", "if true; then echo yes; else echo no; fi", "yes\n"},
    {"; sequencing", "echo one; echo two", "one\ntwo\n"},
    {"a block pipes its whole output onward (v0.1)",
     "for x in a b c; do echo $x; done | upper", "A\nB\nC\n"},
    {"an if-block pipes too (v0.1)",
     "if true; then echo yes; echo more; fi | upper", "YES\nMORE\n"}
  ]

  for {label, cmd, want} <- @commands do
    @cmd cmd
    @want want
    test "#{label} — interp ≡ asm, byte-exact", %{mod: mod} do
      interp = sh(mod, @cmd, false)
      asm = sh(mod, @cmd, true)
      assert interp == @want, "interp: #{inspect(@cmd)} → #{inspect(interp)} want #{inspect(@want)}"
      assert asm == interp, "asm diverged: #{inspect(@cmd)} → asm #{inspect(asm)} vs interp #{inspect(interp)}"
    end
  end

  test "a file redirect persists into the BEAM-resident VFS (/work → TinyLasers.Wasm.VFS)", %{mod: mod} do
    Process.put(:tl_backend, :map)
    Process.put(:tl_vfs, %{})

    out = sh(mod, "echo persisted-by-shell > /work/note.txt", false)
    assert out == "", "a redirect writes the file, not stdout (got #{inspect(out)})"
    # the bytes live in the virtual filesystem (a BEAM term), not in wasm linear memory
    assert Wasm.VFS.get("note.txt") == "persisted-by-shell\n"
  end

  test "grep -c counts matches across file args (v0.1)", %{mod: mod} do
    Process.put(:tl_backend, :map)
    Process.put(:tl_vfs, %{"a.txt" => "x total\ny\n", "b.txt" => "z total\n"})
    assert sh(mod, "grep -c total a.txt b.txt", false) == "2\n"
    assert sh(mod, "echo hay | grep -c hay", false) == "1\n"
  end

  test "bare paths resolve under /work (v0.1) — an agent writes what it means", %{mod: mod} do
    Process.put(:tl_backend, :map)
    Process.put(:tl_vfs, %{})

    assert sh(mod, "echo persisted > note2.txt", false) == ""
    assert Wasm.VFS.get("note2.txt") == "persisted\n"
    # grep is the builtin that reads FILES (cat delegates to host coreutils),
    # so it is the one that proves read_file's bare-path resolution.
    assert sh(mod, "grep persisted note2.txt | upper", false) == "PERSISTED\n"
  end

  test "a HOST program rides the pipeline — grammar from C, the tool from the host", %{mod: mod} do
    # :tl_host_dispatch is the agent shell's seam: any command the shell does
    # not have becomes the host's to answer, mid-pipe. Here the host is a
    # two-line Elixir wc — the same table a wasm coreutils module would ride.
    Process.put(:tl_host_dispatch, fn
      ["wc", "-l"], stdin -> {"#{length(String.split(stdin, "\n", trim: true))}\n", 0}
      _argv, _stdin -> :not_host
    end)

    on_exit(fn -> Process.delete(:tl_host_dispatch) end)

    assert sh(mod, "for x in a b c; do echo $x; done | wc -l", false) == "3\n"
  end
end
