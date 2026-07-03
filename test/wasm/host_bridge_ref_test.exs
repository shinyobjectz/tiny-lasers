# The __host bridge ABI reference concern (docs/host-bridge-abi.md §4): `host_call("echo_up", [s])`
# routes here by the <concern>_<op> naming convention — defined in the embedding app (this test), NOT in
# the runtime, proving concerns need zero tiny-lasers changes.
defmodule TinyLasers.Wasm.HostEcho do
  def call("echo_up", [s]) when is_binary(s), do: String.upcase(s)
end

defmodule TinyLasers.Wasm.HostBridgeRefTest do
  @moduledoc """
  The "hello bridge" — the end-to-end reference for the typed-host-call ABI (docs/host-bridge-abi.md),
  the core-module contract that replaces WIT components for the wasmex cutover:

    host ── tl_alloc + write_bytes + run(ptr,len) ──▶ plain wasm32-wasi CORE guest (zig cc, no libc use)
    guest ── host_call("echo_up", ["<input>"]) ─────▶ concern module (JSON args in, JSON result out)
    host ◀── run returns (ptr<<32)|len ──────────────  "<input>|<UPCASED>"

  Locks every §-numbered convention a compiler backend codegens against: §1 module-agnostic import
  resolution, §2 host_call JSON marshaling + guest-allocated out buffer, §4 concern discovery in the
  embedding app, §5b typed entry (tl_alloc / packed-i64 string return), §6 bounded execution. If this
  breaks, the contract broke — fix the doc or the runtime, never just this test.
  """
  use ExUnit.Case, async: false

  alias TinyLasers.Wasm

  @fixture "test/fixtures/hello_bridge.wasm"

  test "typed host-call round trip on a plain core module (the WIT-component replacement)" do
    bytes = File.read!(@fixture)
    {:ok, mod} = Wasm.decode(bytes)

    # the contract's minimal surface: reactor init + typed entry + guest allocator, ONE host import
    assert Enum.sort(Map.keys(mod.exports)) == ["_initialize", "run", "tl_alloc"]
    assert Enum.map(mod.imports, fn {m, n, _t} -> {m, n} end) == [{"env", "host_call"}]

    input = "hello there bridge"

    # BOUNDED like every guest run (memory + wall-clock capped; a runaway guest dies, never the host).
    {:completed, result} =
      TinyLasers.Gate.bounded(
        fn ->
          {:ok, inst, _out} = Wasm.instance_start(mod, "_initialize", [])

          # §5b: guest-exported alloc → host writes the input string into guest linear memory
          {:ok, ptr, _out, inst} = Wasm.instance_invoke(inst, "tl_alloc", [byte_size(input)])
          Wasm.write_bytes(inst.mem, ptr, input)

          # typed entry: run(ptr, len) -> (ptr <<< 32) ||| len
          {:ok, packed, _out, inst} = Wasm.instance_invoke(inst, "run", [ptr, byte_size(input)])
          import Bitwise
          rptr = packed >>> 32 &&& 0xFFFFFFFF
          rlen = packed &&& 0xFFFFFFFF
          Wasm.read_bytes(inst.mem, rptr, rlen)
        end,
        timeout: 30_000,
        max_heap_size: 268_435_456
      )

    # input echoed + the host concern's upcased answer, joined by the guest — the full round trip
    assert result == "hello there bridge|HELLO THERE BRIDGE"
  end
end
