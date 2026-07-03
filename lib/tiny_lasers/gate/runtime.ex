defmodule TinyLasers.Gate.Runtime do
  @moduledoc """
  The confined runtime for the GuestGate capability-spike.

  This is the ENTIRE host surface a compiled guest may touch. Compiled guest
  bytecode calls only functions in this module — proven structurally by the
  red-team's bytecode inspector (`TinyLasers.Gate.dangerous_refs/1`).

  ## The one load-bearing invariant

      Guest data NEVER crosses into the atom / MFA / raw-fun / raw-pid domain.

  Guest values live in a closed universe:

    * number  -> Elixir float
    * string  -> Elixir binary (NEVER an atom)
    * boolean -> `true` / `false`        (a fixed 2-element atom set, not guest-controllable)
    * absent  -> `:undefined`            (a fixed atom, not guest-controllable)
    * object  -> `{:obj, id}`            (integer handle into the per-process heap)
    * function-> `{:fun, id}`            (integer handle into the per-process closure table)
    * host cap-> `{:host, cap_id}`       (integer handle into the granted-capability registry)

  Because a guest string is a binary and never an atom, and because no operation
  here calls `binary_to_atom` / `list_to_atom` / `apply` / `binary_to_term` on
  guest data, a guest can never *name* a host module. Escape isn't blocked at
  runtime — it is unexpressible.

  The heap, closure table, and run context live in the running process's
  dictionary, so they are per-run, process-local, and reclaimed for free when the
  run process dies (the BEAM-term-offload model).
  """

  # the built-in error constructors (used by `construct`/`call`/`instanceof`).
  @error_names ~w(Error TypeError RangeError SyntaxError ReferenceError EvalError URIError)

  # Array.prototype methods — read as a first-class VALUE they return a bound-method closure so the uncurry
  # pattern `[].slice.call(arguments, 2)` works (preact's `h()` collects variadic children this way). Gated to
  # real methods so `arr.then` / random keys stay undefined (the Promise-duck-typing hazard).
  @arr_methods ~w(map filter reduce reduceRight forEach slice splice push pop shift unshift concat join
                  indexOf lastIndexOf includes find findIndex findLast findLastIndex some every sort reverse
                  flat flatMap fill at copyWithin keys values entries toString toReversed toSorted toSpliced with)

  # static methods on a constructor that code commonly reads as a FIRST-CLASS VALUE (`var f = Array.isArray`);
  # gated so `typeof Array.somethingElse` stays "undefined".
  @global_static_methods ~w(isArray from of fromCharCode fromCodePoint raw
                            isNaN isFinite isInteger isSafeInteger parseFloat parseInt)

  # ── run context setup (host-side; called by the driver, never by guest code) ──

  @doc "Install the run context (granted caps, tenant FS, output buffer) for this process."
  def __init(ctx) do
    Process.put(:gg_ctx, ctx)
    Process.put(:gg_heap, %{})
    Process.put(:gg_funs, %{})
    Process.put(:gg_next, 0)
    Process.put(:gg_out, [])
    Process.put(:gg_fs_writes, [])
    Process.put(:gg_global, {[], %{}})
    Process.put(:gg_microq, :queue.new())
    :ok
  end

  # the global object (globalThis / self / window / top-level `this`) — a singleton mutable object so a UMD
  # bundle can attach its export (`(globalThis).marked = {…}`) and the host can read it back.
  def oget({:globalobj}, k), do: Process.get(:gg_global, {[], %{}}) |> elem(1) |> Map.get(key_str(k), :undefined)

  def oput({:globalobj}, k, v) do
    k = key_str(k)
    {keys, map} = Process.get(:gg_global, {[], %{}})
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    Process.put(:gg_global, {keys, Map.put(map, k, v)})
    {:globalobj}
  end

  @doc "Positional arg fetch for guest closures (keeps the guest's BIF surface off `Enum`)."
  def arg(list, i) when is_list(list), do: Enum.at(list, i, :undefined)
  def arg(_, _), do: :undefined

  def __output, do: Process.get(:gg_out, []) |> Enum.reverse()
  def __ctx, do: Process.get(:gg_ctx)

  defp __id do
    n = Process.get(:gg_next, 0)
    Process.put(:gg_next, n + 1)
    n
  end

  # ── object allocation (handles, not pointers) ──

  @doc "Allocate an object from ordered {key, value} pairs. Returns a `{:obj, id}` handle."
  def obj_new(pairs) do
    id = __id()
    {keys, map} =
      Enum.reduce(pairs, {[], %{}}, fn {k, v}, {ks, m} ->
        k = key_str(k)
        if Map.has_key?(m, k), do: {ks, Map.put(m, k, v)}, else: {ks ++ [k], Map.put(m, k, v)}
      end)

    heap = Process.get(:gg_heap)
    Process.put(:gg_heap, Map.put(heap, id, {keys, map}))
    {:obj, id}
  end

  @doc "Property read. Non-objects read as `:undefined` (no host reach)."
  def get({:obj, id}, key) do
    case Process.get(:gg_heap) |> Map.get(id) do
      {_keys, map} -> Map.get(map, key_str(key), :undefined)
      _ -> :undefined
    end
  end

  def get(_not_obj, _key), do: :undefined

  @doc "Property write. Preserves insertion order. Writing to a non-object is a no-op."
  def set({:obj, id} = o, key, value) do
    k = key_str(key)
    heap = Process.get(:gg_heap)

    case Map.get(heap, id) do
      {keys, map} ->
        keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
        Process.put(:gg_heap, Map.put(heap, id, {keys, Map.put(map, k, value)}))
        value

      _ ->
        o
    end

    value
  end

  def set(_not_obj, _key, value), do: value

  @doc "Ordered own-key list of an object (for the no-atom enumeration red-team)."
  def keys({:obj, id}) do
    case Process.get(:gg_heap) |> Map.get(id) do
      {keys, _map} -> keys
      _ -> []
    end
  end

  def keys(_), do: []

  # ── F2 DIRECT-TERM objects (Phase 1): held directly by the guest, NOT a handle-table entry, so the BEAM
  # GC reclaims unreachable objects (H1). Representation `{keys, map}` — an ordered-key list + a binary-keyed
  # map — is a plain immutable term (no atom/pid/fun), so it is a safe guest value. Mutation is functional
  # (returns a new tuple); the lowering rebinds the local. ──

  @doc "Empty direct-term object."
  def olit, do: {[], %{}}

  # ── boxed closure variables: JS closures share a captured MUTABLE variable BY REFERENCE (counters,
  # accumulators, the module pattern, marked's edit() helper `u = u.replace(...)`). A local that is captured
  # by a nested function AND mutated is stored in a 1-slot box so all closures see the mutation. ──
  @doc "Create a box holding an initial value."
  def box(v) do
    id = Process.get(:gg_box_next, 0)
    Process.put(:gg_box_next, id + 1)
    Process.put({:gg_box, id}, v)
    {:box, id}
  end

  @doc "Read a box."
  @doc "Re-raise an already-wrapped control throw (gg_throw/gg_return/gg_break/…) after a `finally` ran —
  keeps the guest binary free of a direct :erlang.throw reference (confinement gate)."
  def rethrow(e), do: throw(e)

  def box_get({:box, id}), do: Process.get({:gg_box, id}, :undefined)
  # a value bound plain but read as boxed (analysis over-approximated capture): return it as-is.
  def box_get(v), do: v
  @doc "Write a box (returns the value, JS assignment semantics)."
  def box_set({:box, id}, v), do: (Process.put({:gg_box, id}, v); v)
  def box_set(_plain, v), do: v

  @doc """
  `recv.f?.()` support: true iff the receiver is a property-bag (cell/map/global object) whose `key` property
  is nullish — the optional call must yield undefined instead of a not-a-function error. Non-bag receivers
  (strings, arrays, builtins) return false because their methods live in dispatch clauses, not properties.
  """
  def optcall_missing?(obj, key) do
    case obj do
      {:cell, _} -> is_nullish(oget(obj, key))
      {:globalobj} -> is_nullish(oget(obj, key))
      {keys, map} when is_list(keys) and is_map(map) -> is_nullish(oget(obj, key))
      _ -> false
    end
  end

  @doc "Property write. A cell mutates in place (shared); an immutable object returns a NEW object."
  # a property backed by an ACCESSOR routes the write through its SETTER (`this` = the cell); a getter-only
  # accessor makes the write a silent no-op (JS sloppy mode). Non-accessor properties store normally.
  def oput({:cell, _} = c, k, v) do
    case accessor_setter(raw_prop(c, k)) do
      :none ->
        cond do
          # a non-writable OWN data property silently ignores the write (sloppy mode; strict TypeError is P3).
          has_own(c, k) and not prop_writable?(c, k) ->
            c

          # a non-extensible object rejects NEW own properties (freeze/seal/preventExtensions).
          not has_own(c, k) and not extensible?(c) ->
            c

          true ->
            # no OWN accessor — a setter on the PROTOTYPE chain still catches the write (class accessors live on
            # the prototype), invoked with `this` = this instance; a prototype getter-only accessor makes the
            # instance write a silent no-op (sloppy mode). Only walked when the cell has a prototype.
            case proto_setter(c, key_str(k)) do
              :none -> cell_put(c, k, v)
              :readonly -> c
              s -> invoke(s, c, [v]); c
            end
        end

      :readonly ->
        c

      s ->
        invoke(s, c, [v])
        c
    end
  end
  # element write on a typed array mutates the backing buffer and returns the ARRAY — Lower's member-assignment
  # rebinds the root identifier to oput's return, so returning the value would clobber the variable (the
  # rollup native-bridge `u8[i] = buf[i]` loop hit exactly this).
  def oput({:ta, _, _, _, _} = ta, k, v) when is_number(k), do: (ta_set(ta, trunc(k), v); ta)
  # named property on a typed array (JS typed arrays are objects): store in a side table, return the ARRAY
  # (Object.assign(array, {...}) folds oput over the target and relies on it returning the target).
  def oput({:ta, _, _, _, _} = ta, k, v) do
    Process.put({:gg_taprops, ta}, Map.put(Process.get({:gg_taprops, ta}, %{}), key_str(k), v))
    ta
  end
  # Proxy set trap (target, key, value, receiver) — key stays a symbol when it is one.
  def oput({:proxy, t, h} = px, k, v) do
    case oget(h, "set") do
      f when elem(f, 0) in [:fn, :host] -> invoke(f, h, [t, trap_key(k), v, px]); px
      _ -> oput(t, k, v); px
    end
  end
  # `regex.lastIndex = n` updates the stateful match position and RETURNS the regex, so a member-assignment
  # (`re.lastIndex = 0`) doesn't clobber `re` to an empty object — marked's emStrong rDelim loop relies on this.
  def oput({:regex, _, _, _} = r, "lastIndex", v), do: (relast_set(r, trunc(to_number(v))); r)
  def oput({:regex, _, _, _} = r, _k, _v), do: r

  # assigning a function's `.prototype` (Babel `_inherits`: `Ctor.prototype = Object.create(Super.prototype)`)
  # replaces its instance method bag, so `new Ctor()` sees the inherited chain.
  def oput({:fn, f} = fnv, "prototype", v) do
    Process.put(:gg_fnproto, Map.put(Process.get(:gg_fnproto, %{}), f, v))
    fnv
  end

  # `.name`/`.length` are NON-writable: a plain assignment is a silent no-op (sloppy mode). defineProperty
  # can still redefine them (configurable:true) — it writes the override via raw_put, not oput.
  def oput({:fn, _} = fnv, k, _v) when k in ["name", "length"], do: fnv

  # functions are objects: `marked.parse = fn`, `marked.Lexer = ...`. Properties live in a per-function table
  # keyed by the closure identity (mutation is shared, like a cell). Returns the function. A property backed by
  # an accessor setter routes the write through it (static class setters live on the class function object).
  def oput({:fn, _} = fnv, k, v) do
    case accessor_setter(raw_prop(fnv, k)) do
      :none -> fn_put_raw(fnv, k, v)
      :readonly -> fnv
      s -> invoke(s, fnv, [v]); fnv
    end
  end

  defp fn_put_raw({:fn, f} = fnv, k, v) do
    k = key_str(k)
    props = Process.get(:gg_fnprops, %{})
    {keys, map} = Map.get(props, f, {[], %{}})
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    Process.put(:gg_fnprops, Map.put(props, f, {keys, Map.put(map, k, v)}))
    fnv
  end

  def oput({keys, map}, k, v) when is_map(map) do
    k = key_str(k)
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    {keys, Map.put(map, k, v)}
  end

  # arrays can carry NAMED properties (JS arrays are objects): `this.tokens.links = {}` — stored in a props
  # map alongside the elements. Numeric keys write elements; named keys write props.
  def oput({:al, _}, k, _v), do: immut_arr_violation!("oput #{key_str(k)}")
  def oput({:arr, _} = a, k, v), do: arr_put(a, k, v)
  # property write on a primitive is a silent no-op (JS sloppy mode) — return the RECEIVER unchanged so a
  # root-identifier rebind doesn't replace a number/string/undefined with an empty object.
  # writing a property OF null/undefined is a TypeError (spec). Other non-objects silently no-op (sloppy).
  def oput(:undefined, k, _v), do: type_error("Cannot set properties of undefined (setting '#{key_str(k)}')")
  def oput(:null, k, _v), do: type_error("Cannot set properties of null (setting '#{key_str(k)}')")
  def oput(not_obj, _k, _v), do: not_obj

  # write to an array IN PLACE: numeric key → element slot; named key → the props map. Returns the same handle.
  defp arr_put({:al, _}, k, _v), do: immut_arr_violation!("arr_put #{key_str(k)}")
  defp arr_put({:arr, _} = a, k, v) do
    list = al(a)
    props = ap(a)

    case arr_index(k) do
      nil ->
        aset(a, list, Map.put(props, key_str(k), v))

      idx when idx >= 0 and idx < 1_000_000 ->
        list = if idx >= length(list), do: list ++ List.duplicate(:undefined, idx - length(list) + 1), else: list
        aset(a, List.replace_at(list, idx, v), props)

      # an out-of-sane-range index (from a NaN/huge computed key) is treated as a named prop, never a giant list.
      idx ->
        aset(a, list, Map.put(props, Integer.to_string(idx), v))
    end
  end

  defp arr_index(i) when is_number(i), do: trunc(i)
  defp arr_index(k) when is_binary(k), do: (case Integer.parse(k) do {n, ""} when n >= 0 -> n; _ -> nil end)
  defp arr_index(_), do: nil

  @doc "Property read. Objects: by key. Arrays: numeric index + `length`. Non-objects: `:undefined`."
  # cell property read WITH prototype-chain fallback: ES5 classes put methods on `Ctor.prototype`; a `new
  # Ctor()` instance resolves a missing own-property from its linked prototype (see construct/2, fn_proto/1).
  def oget({:cell, id} = c, "size") do
    case Process.get({:gg_cellcoll, id}) do
      nil -> cell_oget(c, "size", c)
      coll -> oget(coll, "size")
    end
  end
  def oget({:cell, id} = c, k) do
    # a cell backed by a real array (class extends Array) exposes the array's length + indexed elements; other
    # keys (custom props/methods) come from the cell.
    case Process.get({:gg_cellarr, id}) do
      nil ->
        cell_oget(c, key_str(k), c)

      arr ->
        cond do
          k == "length" or arr_index(k) != nil ->
            oget(arr, k)

          true ->
            # custom props/methods (via the subclass prototype) win; fall back to the array's own method as a
            # first-class value (`var f = nodeList.forEach`) when the subclass doesn't define it. The closure
            # binds to the BACKING ARRAY (not `this`) — else method({:cell},…) would re-read oget→closure→invoke
            # forever.
            v = cell_oget(c, key_str(k), c)
            if v == :undefined and is_binary(k) and k in @arr_methods,
              do: closure(fn _this, cargs -> method(arr, k, cargs) end),
              else: v
        end
    end
  end

  # resolve a cell property through the prototype chain; a `{:getter, fn}` marker is invoked with `this` = the
  # ORIGINAL receiver (so a prototype getter reading the instance's scope state works).
  defp cell_oget({:cell, id} = c, key, recv) do
    case Map.get(cell_read(c) |> elem(1), key, :__miss) do
      :__miss ->
        case Process.get({:gg_instproto, id}) do
          nil -> :undefined
          {:cell, _} = proto -> cell_oget(proto, key, recv)
          proto -> deget(oget(proto, key), recv)
        end

      {:getter, f} ->
        invoke(f, recv, [])

      {:accessor, :undefined, _} ->
        :undefined

      {:accessor, g, _} ->
        invoke(g, recv, [])

      v ->
        v
    end
  end

  defp deget({:getter, f}, recv), do: invoke(f, recv, [])
  defp deget({:accessor, :undefined, _}, _recv), do: :undefined
  defp deget({:accessor, g, _}, recv), do: invoke(g, recv, [])
  defp deget(v, _recv), do: v

  # ── accessor properties: {:accessor, get, set} (get/set are fn-values or :undefined). {:getter, f} is the
  # legacy get-only alias, treated the same. `accessor_setter/1` reports what a WRITE should do.
  defp accessor_setter({:accessor, _g, :undefined}), do: :readonly
  defp accessor_setter({:accessor, _g, s}), do: s
  defp accessor_setter({:getter, _}), do: :readonly
  defp accessor_setter(_), do: :none

  # walk the prototype chain for an accessor whose setter catches an instance write. :none = no accessor found
  # (write proceeds to an own property); a value = the setter fn; :readonly = getter-only (write is a no-op).
  defp proto_setter({:cell, id}, kstr) do
    case Process.get({:gg_instproto, id}) do
      nil ->
        :none

      {:cell, _} = proto ->
        case accessor_setter(raw_prop(proto, kstr)) do
          :none -> proto_setter(proto, kstr)
          found -> found
        end

      proto ->
        accessor_setter(raw_prop(proto, kstr))
    end
  end

  defp proto_setter(_, _), do: :none

  @doc "RAW property read — returns the STORED value/marker (an accessor is NOT invoked). Used by
  defineProperty (to merge get+set) and by the setter-aware write path."
  def raw_prop({:cell, _} = c, k), do: Map.get(cell_read(c) |> elem(1), key_str(k), :undefined)
  def raw_prop({:fn, f}, k), do: Process.get(:gg_fnprops, %{}) |> Map.get(f, {[], %{}}) |> elem(1) |> Map.get(key_str(k), :undefined)
  def raw_prop({keys, map}, k) when is_list(keys) and is_map(map), do: Map.get(map, key_str(k), :undefined)
  def raw_prop(_, _), do: :undefined

  @doc "RAW property store — bypasses accessor-setter invocation (installs the marker itself)."
  def raw_put({:cell, _} = c, k, v), do: cell_put(c, k, v)
  def raw_put({:fn, _} = f, k, v), do: fn_put_raw(f, k, v)
  def raw_put(o, k, v), do: oput(o, k, v)

  @doc "Install/merge an accessor half. `kind` is \"get\" or \"set\"; merges with any existing accessor at the
  key so `{ get x(){}, set x(v){} }` (two properties, same key) becomes one `{:accessor, g, s}`. Returns obj."
  def put_accessor(obj, key, kind, fun) do
    {g, s} =
      case raw_prop(obj, key) do
        {:accessor, cg, cs} -> {cg, cs}
        {:getter, cg} -> {cg, :undefined}
        _ -> {:undefined, :undefined}
      end

    raw_put(obj, key, if(kind == "get", do: {:accessor, fun, s}, else: {:accessor, g, fun}))
    obj
  end

  # a function's `.prototype` is a stable per-function cell (ES5 method bag: `Ctor.prototype.m = fn`).
  def oget({:fn, _} = fnv, "prototype"), do: fn_proto(fnv)
  # `.name`/`.length` are own configurable props: a user override (defineProperty/assignment, in gg_fnprops)
  # wins; otherwise the value is the metadata recorded at creation (fn_meta/set_fn_name).
  def oget({:fn, f} = fnv, "name"), do: (case raw_prop(fnv, "name") do :undefined -> (if fn_deleted?(f, "name"), do: "", else: fn_name_meta(f)); v -> v end)
  def oget({:fn, f} = fnv, "length"), do: (case raw_prop(fnv, "length") do :undefined -> (if fn_deleted?(f, "length"), do: 0.0, else: fn_len_meta(f) * 1.0); v -> v end)
  # a {:getter, g} marker on a function object (static class accessor via defineProperty) is invoked on read.
  def oget({:fn, f} = fnv, k) do
    case Process.get(:gg_fnprops, %{}) |> Map.get(f, {[], %{}}) |> elem(1) |> Map.get(key_str(k), :undefined) do
      {:getter, g} -> invoke(g, fnv, [])
      {:accessor, :undefined, _} -> :undefined
      {:accessor, g, _} -> invoke(g, fnv, [])
      v -> v
    end
  end
  def oget({_keys, map}, k) when is_map(map), do: Map.get(map, key_str(k), :undefined)
  def oget({:set, _} = st, "size"), do: length(set_list(st)) * 1.0
  def oget({:map, _} = mp, "size"), do: length(map_pairs(mp)) * 1.0
  # Proxy get trap (falls back to the target). The trap receives (target, key, receiver) — key stays a
  # SYMBOL when it is one (rollup: `bundle[lowercaseBundleKeys]` compares the trapped key with ===).
  def oget({:proxy, t, h} = px, k) do
    case oget(h, "get") do
      f when elem(f, 0) in [:fn, :host] -> invoke(f, h, [t, trap_key(k), px])
      _ -> oget(t, k)
    end
  end

  defp trap_key({:symbol, _, _} = s), do: s
  defp trap_key(k), do: key_str(k)
  def oget({:bytes, b}, k) when k in ["length", "byteLength"], do: byte_size(b) * 1.0
  def oget({:bytes, _}, "byteOffset"), do: 0.0
  def oget({:bytes, b}, k) when is_number(k), do: (i = trunc(k); if i >= 0 and i < byte_size(b), do: :binary.at(b, i) * 1.0, else: :undefined)
  def oget({:bytes, _}, _), do: :undefined

  # typed-array views + ArrayBuffers
  def oget({:ta, _, _, _, _} = ta, k) when is_number(k), do: ta_get(ta, trunc(k))
  def oget({:ta, _, _, _, len}, "length"), do: len * 1.0
  def oget({:ta, kind, _, _, len}, "byteLength"), do: len * ta_size(kind) * 1.0
  def oget({:ta, _, _, off, _}, "byteOffset"), do: off * 1.0
  def oget({:ta, kind, _, _, _}, "BYTES_PER_ELEMENT"), do: ta_size(kind) * 1.0
  def oget({:ta, _, id, _, _}, "buffer"), do: {:abuf, id, byte_size(abuf_bin(id))}
  def oget({:ta, _, _, _, _} = ta, key), do: Process.get({:gg_taprops, ta}, %{}) |> Map.get(key_str(key), :undefined)
  def oget({:abuf, _, blen}, "byteLength"), do: blen * 1.0
  def oget({:abuf, _, _}, _), do: :undefined

  def oget({t, _} = a, k) when t in [:arr, :al] do
    cond do
      k == "length" -> length(al(a)) * 1.0
      (idx = arr_index(k)) != nil -> Enum.at(al(a), idx, :undefined)
      is_binary(k) and k in @arr_methods -> closure(fn this, args -> method(this, k, args) end)
      true -> Map.get(ap(a), key_str(k), :undefined)
    end
  end

  # a generator/iterator object: Symbol.iterator returns itself; the protocol methods read as first-class values.
  def oget({:geniter, _} = g, {:symbol, "@@iterator", _}), do: closure(fn _this, _ -> g end)
  def oget({:geniter, _}, k) when k in ["next", "return", "throw"], do: closure(fn this, args -> method(this, k, args) end)
  def oget({:geniter, _}, _), do: :undefined

  # regex properties (marked's edit() helper reads `re.source` to compose patterns as strings).
  def oget({:regex, _re, src, _flags}, "source"), do: src
  def oget({:regex, _re, _src, flags}, "flags"), do: flags
  def oget({:regex, _re, _src, flags}, "global"), do: String.contains?(flags, "g")
  def oget({:regex, _re, _src, flags}, "ignoreCase"), do: String.contains?(flags, "i")
  def oget({:regex, _re, _src, flags}, "multiline"), do: String.contains?(flags, "m")
  def oget({:regex, _, _, _} = r, "lastIndex"), do: relast_get(r) * 1.0

  # string properties: `.length` and index access `s[i]` (JS returns a 1-char string).
  # string length/index are by CODE POINT (JS string semantics), with an all-ASCII fast path (bytes==code
  # points → the O(1) byte op is already correct). acorn's unicode identifier tokenizer needs this.
  def oget(s, "length") when is_binary(s), do: str_len(s) * 1.0
  def oget(s, i) when is_binary(s) and is_number(i) do
    idx = trunc(i)
    cond do
      idx < 0 -> :undefined
      ascii?(s) -> (if idx < byte_size(s), do: binary_part(s, idx, 1), else: :undefined)
      true -> (case Enum.at(safe_charlist(s), idx) do nil -> :undefined; cp -> List.to_string([cp]) end)
    end
  end

  # String.prototype methods as first-class VALUES — `const {replace} = ""; replace.call(es, …)` (linkedom's
  # serializer) reads the method off a string and calls it with an explicit receiver. The closure binds `this`
  # at call time (via .call/.apply or direct invoke), so `method(this, name, args)` dispatches to the real one.
  @str_methods ~w(at charAt charCodeAt codePointAt concat endsWith includes indexOf lastIndexOf match matchAll
                  normalize padEnd padStart repeat replace replaceAll search slice split startsWith substr
                  substring toLowerCase toString toUpperCase trim trimEnd trimLeft trimRight trimStart valueOf)
  def oget(s, k) when is_binary(s) and is_binary(k) and k in @str_methods,
    do: closure(fn this, args -> method(this, k, args) end)

  @doc "global namespace/property reads (Math.PI, Number.MAX_VALUE, Object.prototype)."
  # Math functions callable as first-class VALUES (GSAP/easing libs alias `var _sin = Math.sin; _sin(x)`).
  @math_fns ~w(floor ceil round trunc abs sqrt cbrt pow sin cos tan asin acos atan atan2 sinh cosh tanh exp
               expm1 log log2 log10 log1p hypot max min sign random)
  def oget({:global, "Math"}, "PI"), do: :math.pi()
  def oget({:global, "Math"}, "E"), do: :math.exp(1)
  def oget({:global, "Math"}, "LN2"), do: :math.log(2)
  def oget({:global, "Math"}, "LN10"), do: :math.log(10)
  def oget({:global, "Math"}, "LOG2E"), do: 1 / :math.log(2)
  def oget({:global, "Math"}, "LOG10E"), do: 1 / :math.log(10)
  def oget({:global, "Math"}, "SQRT2"), do: :math.sqrt(2)
  def oget({:global, "Math"}, "SQRT1_2"), do: :math.sqrt(0.5)
  def oget({:global, "Math"}, name) when name in @math_fns, do: closure(fn _this, args -> math_static(name, args) end)
  def oget({:global, "Number"}, "MAX_VALUE"), do: 1.7976931348623157e308
  def oget({:global, "Number"}, "MIN_VALUE"), do: 5.0e-324
  def oget({:global, "Number"}, "MAX_SAFE_INTEGER"), do: 9_007_199_254_740_991.0
  # the Object static methods callable as first-class values (esbuild aliases `var f = Object.defineProperty`).
  @obj_statics ~w(keys values entries getOwnPropertyNames getOwnPropertyDescriptor getOwnPropertyDescriptors
                  assign create freeze defineProperty defineProperties getPrototypeOf setPrototypeOf fromEntries hasOwn
                  seal preventExtensions isExtensible isFrozen isSealed)

  # well-known symbols: stable, shared identities (Symbol.iterator etc. must compare equal across reads).
  def oget({:global, "Symbol"}, k) when k in ["iterator", "asyncIterator", "hasInstance", "toPrimitive", "toStringTag"],
    do: {:symbol, "@@" <> k, k}
  def oget({:global, "Symbol"}, "for"), do: closure(fn _this, args -> (d = to_str(List.first(args) || ""); {:symbol, "for:" <> d, d}) end)
  # legacy static RegExp.$1…$9 — the last successful match's capture groups (group N; $0 isn't a thing).
  def oget({:global, "RegExp"}, <<?$, d>>) when d in ?1..?9 do
    case Enum.at(Process.get(:gg_re_lastmatch, []), d - ?0) do
      s when is_binary(s) -> s
      _ -> ""
    end
  end

  # Date.now as a first-class VALUE (not just Date.now()) — GSAP does `var _getTime = Date.now; _getTime()`.
  def oget({:global, "Date"}, "now"), do: closure(fn _this, _args -> method({:global, "Date"}, "now", []) end)

  def oget({:global, name}, "prototype"), do: {:proto, name}
  # a constructor's `.name` (Array.name === "Array", TypeError.name === "TypeError") — used by assert.throws
  # and many descriptor tests.
  def oget({:global, name}, "name"), do: name
  # a global static method read as a first-class value: return a closure bound to the method dispatcher so
  # `var f = Object.defineProperty; f(o,k,d)` works (esbuild wrapper pattern). Gated to known statics so
  # `typeof Object.somethingElse` stays "undefined".
  def oget({:global, "Object"}, k) when is_binary(k) and k not in ["prototype"] do
    if k in @obj_statics, do: closure(fn _this, args -> object_static(k, args) end), else: :undefined
  end
  def oget({:global, "Promise"}, k) when k in ["resolve", "reject", "all", "allSettled", "race"],
    do: closure(fn _this, args -> promise_static(k, args) end)
  def oget({:global, "Reflect"}, k) when k in ["get", "set", "has", "ownKeys", "deleteProperty", "getPrototypeOf", "defineProperty", "construct", "apply"],
    do: closure(fn _this, args -> reflect_static(k, args) end)
  # a constructor's static method read as a first-class value (`var f = Array.isArray; f([1])`) → a closure
  # bound to the method dispatcher.
  def oget({:global, name}, k) when is_binary(k) and k in @global_static_methods,
    do: closure(fn _this, args -> method({:global, name}, k, args) end)
  def oget({:global, _}, _), do: :undefined

  def oget({:proto, name}, "constructor"), do: {:global, name}
  def oget({:proto, _}, "toString"), do: {:protom, :tostring}
  def oget({:proto, _}, "hasOwnProperty"), do: {:protom, :hasown}
  def oget({:proto, _}, "propertyIsEnumerable"), do: {:protom, :propisenum}
  # Promise duck-typing sentinels: no built-in prototype EXCEPT Promise has then/catch/finally. The generic
  # closure fallback below would return a TRUTHY closure for them on Error/Array/… making every object look
  # thenable and breaking `if (x.then)` promise detection (preact-render-to-string mis-reads a thrown error as
  # a suspension). Return undefined — but keep them real on Promise.prototype (preact's hooks scheduler does
  # `Promise.prototype.then.bind(Promise.resolve())`).
  def oget({:proto, name}, meth) when meth in ["then", "catch", "finally"] and name != "Promise", do: :undefined
  # any other prototype method (`Array.prototype.slice.call(arguments, 1)`): a closure that dispatches the
  # named method on the receiver, so .call/.apply/.bind ride the normal {:fn} machinery.
  def oget({:proto, _}, meth) when is_binary(meth), do: closure(fn this, args -> method(this, meth, args) end)
  def oget({:proto, _}, _), do: :undefined

  # reading a property OF null/undefined is a TypeError (spec) — NOT lenient. Other non-objects (numbers,
  # booleans) box to a wrapper with no such property → undefined, so they stay lenient below.
  def oget(:undefined, k), do: type_error("Cannot read properties of undefined (reading '#{key_str(k)}')")
  def oget(:null, k), do: type_error("Cannot read properties of null (reading '#{key_str(k)}')")
  def oget(_not_obj, _k), do: :undefined

  @doc "Spread-merge b's own keys into cell a in order (`{...a, ...b}` / Object.assign). Mutates & returns a."
  def omerge({:cell, _} = a, b) do
    Enum.reduce(spread_keys(b), a, fn k, acc -> oput(acc, k, oget(b, k)) end)
  end

  # own-enumerable keys of a spread source; non-objects (undefined/null/number/string) contribute nothing.
  defp spread_keys({:cell, _} = c), do: okeys(c)
  defp spread_keys({keys, map}) when is_map(map), do: keys
  defp spread_keys({:globalobj}), do: okeys({:globalobj})
  defp spread_keys(_), do: []

  def omerge({:cell, _} = c, b), do: omerge(cell_read(c), b)
  def omerge(a, {:cell, _} = c), do: omerge(a, cell_read(c))
  def omerge(a, _non_obj), do: a

  @doc "Ordered own-keys of a direct-term object."
  def okeys({keys, map}) when is_map(map), do: keys
  # enumerable own keys only (Object.keys / for-in / spread / JSON): a property marked non-enumerable via
  # defineProperty is skipped. Default (no overlay entry) is enumerable, so ordinary objects are unaffected.
  def okeys({:cell, _} = c), do: (cell_read(c) |> elem(0) |> Enum.filter(&prop_enumerable?(c, &1)))
  def okeys({:globalobj}), do: Process.get(:gg_global, {[], %{}}) |> elem(0)
  # Proxy ownKeys trap → the enumerable keys (falls back to the target's).
  def okeys({:proxy, t, h}) do
    case oget(h, "ownKeys") do
      f when elem(f, 0) in [:fn, :host] -> arr_to_list(invoke(f, h, [t]))
      _ -> okeys(t)
    end
  end
  def okeys(_), do: []

  # ── MUTABLE CELL objects (stateful instances: things with methods, e.g. a Lexer/Parser). Few and long-
  # lived, so a per-run process-dict table is fine (the GC concern is the transient object FLOOD, which stays
  # immutable {keys,map}). A cell mutates IN PLACE, so `this.x = v` and shared-object aliasing work. The guest
  # holds only the integer id inside {:cell, id} — still no atom/pid/fun crosses the boundary. ──
  @doc "Allocate a mutable-cell object from ordered {key, value} pairs. Returns `{:cell, id}`."
  def cell_new(pairs) do
    id = cell_id()
    {keys, map} =
      Enum.reduce(pairs, {[], %{}}, fn {k, v}, {ks, m} ->
        k = key_str(k)
        if Map.has_key?(m, k), do: {ks, Map.put(m, k, v)}, else: {ks ++ [k], Map.put(m, k, v)}
      end)

    Process.put(:gg_cells, Map.put(Process.get(:gg_cells, %{}), id, {keys, map}))
    {:cell, id}
  end

  defp cell_id do
    n = Process.get(:gg_cell_next, 0)
    Process.put(:gg_cell_next, n + 1)
    n
  end

  defp cell_read({:cell, id}), do: Process.get(:gg_cells, %{}) |> Map.get(id, {[], %{}})

  # ── per-property attribute overlay (P1) ──────────────────────────────────────────────────────────────────
  # A SPARSE map `:gg_pattr = %{{cell_id, keystr} => {writable, enumerable, configurable}}`. Absent ⇒ the
  # default DATA property {true, true, true} — so a plain assignment records NOTHING and behaves exactly as
  # before (zero regression). Only Object.defineProperty / freeze / seal write entries, so only explicitly
  # attributed properties diverge from the default. Non-cell objects have no overlay (always default).
  defp pattr_get({:cell, id}, k), do: Process.get(:gg_pattr, %{}) |> Map.get({id, key_str(k)}, {true, true, true})
  defp pattr_get(_, _), do: {true, true, true}
  defp pattr_put({:cell, id}, k, {_w, _e, _c} = a), do: Process.put(:gg_pattr, Map.put(Process.get(:gg_pattr, %{}), {id, key_str(k)}, a))
  defp pattr_put(_, _, _), do: :ok
  defp pattr_del({:cell, id}, k), do: Process.put(:gg_pattr, Map.delete(Process.get(:gg_pattr, %{}), {id, key_str(k)}))
  defp pattr_del(_, _), do: :ok

  defp prop_writable?(o, k), do: elem(pattr_get(o, k), 0)
  defp prop_enumerable?(o, k), do: elem(pattr_get(o, k), 1)
  defp prop_configurable?(o, k), do: elem(pattr_get(o, k), 2)

  # extensibility: a set of non-extensible cell ids (Object.preventExtensions/seal/freeze). A non-extensible
  # object rejects NEW own properties (existing writes still apply).
  defp mark_nonextensible({:cell, id}), do: Process.put(:gg_nonext, MapSet.put(Process.get(:gg_nonext, MapSet.new()), id))
  defp mark_nonextensible(_), do: :ok
  defp extensible?({:cell, id}), do: not MapSet.member?(Process.get(:gg_nonext, MapSet.new()), id)
  defp extensible?(_), do: false

  # ALL own string keys of a cell (getOwnPropertyNames — includes non-enumerable); okeys is enumerable-only.
  defp own_keys_all({:cell, _} = c), do: elem(cell_read(c), 0)
  defp own_keys_all(o), do: okeys(o)

  @doc "In-place property write on a cell. Returns the SAME handle (mutation is shared)."
  def cell_put({:cell, id} = c, k, v) do
    k = key_str(k)
    {keys, map} = cell_read(c)
    keys = if Map.has_key?(map, k), do: keys, else: keys ++ [k]
    Process.put(:gg_cells, Map.put(Process.get(:gg_cells, %{}), id, {keys, Map.put(map, k, v)}))
    c
  end

  @doc "Functional index/key write. Arrays grow to fit; objects add the key. Returns a NEW term."
  def oput_idx({:al, _}, i, _v), do: immut_arr_violation!("oput_idx #{inspect(i)}")
  def oput_idx({:arr, _} = a, i, v), do: arr_put(a, i, v)
  # a cell member write goes through the accessor-aware `oput` (Lower's `o.x = v` rebind lowers to oput_idx —
  # it must invoke a setter, not raw-store past it).
  def oput_idx({:cell, _} = c, k, v), do: oput(c, k, v)
  def oput_idx({:globalobj}, k, v), do: oput({:globalobj}, k, v)
  def oput_idx(other, k, v), do: oput(other, k, v)

  @doc "method call on the global object (globalThis.marked(md))."
  def method({:globalobj} = g, name, args) do
    case oget(g, name) do
      {:fn, _} = f -> invoke(f, g, args)
      _ -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP globalmeth #{inspect(name)}"); guest_error("not a function")
    end
  end

  # ── arrays are MUTABLE REFERENCES (JS array semantics): `{:arr, id}` indexes a per-run table holding
  # `{elements, named_props}`. push/pop/… mutate in place so aliases + params share the mutation (marked's
  # `blockTokens(src, this.tokens)` pushes into the caller's array). Non-mutating ops return a NEW array. ──
  @doc "Allocate a mutable array."
  def avec(list, props \\ %{}) when is_list(list) do
    id = Process.get(:gg_vec_next, 0)
    Process.put(:gg_vec_next, id + 1)
    Process.put({:gg_vec, id}, {list, props})
    {:arr, id}
  end

  @doc """
  Allocate an IMMUTABLE array literal — a plain `{:al, list}` direct term with NO `{:gg_vec}` handle, so the
  BEAM GC reclaims it when unreachable (the object-store-leak fix, Lever 2). Lower emits this (instead of the
  mutable `alit/1`) ONLY where a conservative use-whitelist proves the binding never escapes and is never
  mutated (see Lower's `immut_arr_vars/1`).
  """
  def alit_i(list) when is_list(list), do: {:al, list}

  # A mutating op reached an {:al} immutable array — means Lower's escape/mutation analysis was UNSOUND. Fail
  # LOUD (never silently corrupt): a differential run vs Walk turns this into a visible divergence/crash.
  defp immut_arr_violation!(op),
    do: raise("F2 immutable-array (escape-analysis) bug: mutating op `#{op}` reached an {:al} array")

  @doc "A rest parameter's array: the args from index `i` onward. (Keeps Enum.drop out of emitted guest code.)"
  def args_rest(args, i) when is_list(args), do: avec(Enum.drop(args, i))

  @doc "Public accessor: a guest array's element list (for host capability bridges reading guest arrays)."
  def arr_to_list({t, _} = a) when t in [:arr, :al], do: al(a)
  def arr_to_list(_), do: []

  defp bytes_bin({:bytes, b}), do: b
  defp bytes_bin(b) when is_binary(b), do: b
  defp bytes_bin(_), do: ""

  # coerce a byte source (Buffer/typed array/array-of-bytes/binary) to a binary (TextDecoder.decode).
  defp to_bin_bytes({:bytes, b}), do: b
  defp to_bin_bytes(b) when is_binary(b), do: b
  defp to_bin_bytes({:ta, _, _, _, _} = ta), do: ta_bytes(ta)
  defp to_bin_bytes({:arr, _} = a), do: al(a) |> Enum.map(&(trunc(to_number(&1)) |> Bitwise.band(0xFF))) |> :erlang.list_to_binary()
  defp to_bin_bytes(_), do: ""

  # ── ArrayBuffer + typed-array views ──────────────────────────────────────────────────────────────────────
  def mk_abuf(bin) do
    id = __id()
    Process.put({:gg_abuf, id}, bin)
    {:abuf, id, byte_size(bin)}
  end

  defp abuf_bin(id), do: Process.get({:gg_abuf, id}, "")
  defp abuf_put(id, bin), do: Process.put({:gg_abuf, id}, bin)

  defp ta_kind("Uint8Array"), do: :u8
  defp ta_kind("Int8Array"), do: :i8
  defp ta_kind("Uint16Array"), do: :u16
  defp ta_kind("Int16Array"), do: :i16
  defp ta_kind("Uint32Array"), do: :u32
  defp ta_kind("Int32Array"), do: :i32
  defp ta_kind("Float32Array"), do: :f32
  defp ta_kind("Float64Array"), do: :f64

  defp ta_size(k) when k in [:u8, :i8], do: 1
  defp ta_size(k) when k in [:u16, :i16], do: 2
  defp ta_size(k) when k in [:u32, :i32, :f32], do: 4
  defp ta_size(:f64), do: 8

  defp ta_enc(:u8, v), do: <<Bitwise.band(ta_int(v), 0xFF)::unsigned-8>>
  defp ta_enc(:i8, v), do: <<ta_int(v)::signed-8>>
  defp ta_enc(:u16, v), do: <<Bitwise.band(ta_int(v), 0xFFFF)::unsigned-little-16>>
  defp ta_enc(:i16, v), do: <<ta_int(v)::signed-little-16>>
  defp ta_enc(:u32, v), do: <<Bitwise.band(ta_int(v), 0xFFFFFFFF)::unsigned-little-32>>
  defp ta_enc(:i32, v), do: <<ta_int(v)::signed-little-32>>
  defp ta_enc(:f32, v), do: <<ta_float(v)::float-little-32>>
  defp ta_enc(:f64, v), do: <<ta_float(v)::float-little-64>>

  # JS typed-array element write COERCES (ToNumber then truncate/wrap) and never throws — NaN/Infinity/non-number
  # store as 0 in integer views (`new Uint8Array([NaN])[0] === 0`). Was `trunc(v)`, which crashed on :nan/:infinity.
  defp ta_int(v) when is_number(v), do: trunc(v)
  defp ta_int(_), do: 0
  defp ta_float(v) when is_number(v), do: v / 1
  defp ta_float(_), do: 0.0

  defp ta_dec(:u8, <<v::unsigned-8>>), do: v * 1.0
  defp ta_dec(:i8, <<v::signed-8>>), do: v * 1.0
  defp ta_dec(:u16, <<v::unsigned-little-16>>), do: v * 1.0
  defp ta_dec(:i16, <<v::signed-little-16>>), do: v * 1.0
  defp ta_dec(:u32, <<v::unsigned-little-32>>), do: v * 1.0
  defp ta_dec(:i32, <<v::signed-little-32>>), do: v * 1.0
  defp ta_dec(:f32, <<v::float-little-32>>), do: v
  defp ta_dec(:f64, <<v::float-little-64>>), do: v
  defp ta_dec(_, _), do: :nan

  defp ta_from_elems(kind, elems) do
    sz = ta_size(kind)
    bin = elems |> Enum.map(fn v -> ta_enc(kind, to_number(v)) end) |> IO.iodata_to_binary()
    {:abuf, id, _} = mk_abuf(bin)
    {:ta, kind, id, 0, div(byte_size(bin), sz)}
  end

  # element read/write via the underlying buffer at byte_off + i*size.
  defp ta_get({:ta, kind, id, off, len}, i) when i >= 0 and i < len do
    sz = ta_size(kind)
    pos = off + i * sz
    bin = abuf_bin(id)
    if pos + sz <= byte_size(bin), do: ta_dec(kind, binary_part(bin, pos, sz)), else: :undefined
  end
  defp ta_get({:ta, kind, _, _, len}, i) do
    if System.get_env("GAPLOG"), do: IO.puts(:stderr, "TA-OOB #{kind} idx=#{i} len=#{len}")
    :undefined
  end

  defp ta_set({:ta, kind, id, off, _len}, i, v) do
    sz = ta_size(kind)
    pos = off + i * sz
    bin = abuf_bin(id)
    if pos + sz <= byte_size(bin) do
      abuf_put(id, binary_part(bin, 0, pos) <> ta_enc(kind, to_number(v)) <> binary_part(bin, pos + sz, byte_size(bin) - pos - sz))
    end
    v
  end

  defp ta_elems({:ta, _, _, _, len} = ta), do: for(i <- 0..(len - 1)//1, do: ta_get(ta, i))
  defp ta_elems(_), do: []

  # DataView: map get/set<Kind> → element kind; big/little endian.
  defp dv_kind("Float64"), do: :f64
  defp dv_kind("Float32"), do: :f32
  defp dv_kind("Uint32"), do: :u32
  defp dv_kind("Int32"), do: :i32
  defp dv_kind("Uint16"), do: :u16
  defp dv_kind("Int16"), do: :i16
  defp dv_kind("Uint8"), do: :u8
  defp dv_kind("Int8"), do: :i8
  defp dv_kind(_), do: :u8

  defp dv_get(kind, bin, pos, le) do
    sz = ta_size(kind)
    if pos >= 0 and pos + sz <= byte_size(bin) do
      raw = binary_part(bin, pos, sz)
      raw = if le, do: raw, else: dv_swap(raw)
      ta_dec(kind, raw)
    else
      :undefined
    end
  end

  defp dv_set(id, kind, pos, v, le) do
    sz = ta_size(kind)
    bin = abuf_bin(id)
    if pos >= 0 and pos + sz <= byte_size(bin) do
      enc = ta_enc(kind, v)
      enc = if le, do: enc, else: dv_swap(enc)
      abuf_put(id, binary_part(bin, 0, pos) <> enc <> binary_part(bin, pos + sz, byte_size(bin) - pos - sz))
    end
  end

  # ta_enc/ta_dec are little-endian; big-endian DataView access reverses the bytes.
  defp dv_swap(bin), do: bin |> :binary.bin_to_list() |> Enum.reverse() |> :erlang.list_to_binary()
  # the raw bytes this view spans (for TextDecoder / Buffer.from).
  defp ta_bytes({:ta, kind, id, off, len}), do: binary_part(abuf_bin(id), off, min(len * ta_size(kind), byte_size(abuf_bin(id)) - off))

  @doc "Granted `__host(op, params)` capability bridge → dispatches to a host module (e.g. the rollup
  wasm parser via HostRollup) and returns the result as a guest object. Confined: the guest holds only the
  integer capability handle; the host work (running wasm) happens here, never referenced in guest code."
  def host_rollup_bridge([op, params | _], _ctx) do
    plist = arr_to_list(params)
    case TinyLasers.Wasm.HostRollup.call(to_string(op), plist) do
      m when is_map(m) -> cell_new(Enum.map(m, fn {k, v} -> {to_string(k), v} end))
      other -> other
    end
  end

  defp al({:arr, id}), do: Process.get({:gg_vec, id}, {[], %{}}) |> elem(0)
  # {:al, list} — an IMMUTABLE array: a plain direct BEAM term (no {:gg_vec} handle), so BEAM's GC reclaims it
  # when unreachable. Lower emits it only for array literals a conservative escape/mutation analysis proves are
  # non-escaping AND never mutated (see f2-object-store-leak) — so ONLY the read paths below are ever reached;
  # every mutating op raises (a loud analysis-bug signal, never silent corruption).
  defp al({:al, list}) when is_list(list), do: list
  defp ap({:arr, id}), do: Process.get({:gg_vec, id}, {[], %{}}) |> elem(1)
  defp ap({:al, _}), do: %{}
  defp aset({:arr, id} = a, list, props), do: (Process.put({:gg_vec, id}, {list, props}); a)
  defp aset_l({:arr, _} = a, list), do: aset(a, list, ap(a))

  # overwrite `dst` from index `off` with `src` elements (typed-array .set), keeping the rest.
  defp ta_set(dst, src, off) do
    dst = List.to_tuple(dst)
    Enum.reduce(Enum.with_index(src), dst, fn {v, i}, acc ->
      idx = off + i
      if idx >= 0 and idx < tuple_size(acc), do: put_elem(acc, idx, v), else: acc
    end)
    |> Tuple.to_list()
  end

  @doc "Array literal from evaluated elements."
  def alit(elems) when is_list(elems), do: avec(elems)

  # Build a nested array/object from a BEAM-literal term (large CONSTANT literals — e.g. linkedom's HTML entity
  # tables — fold to this in Lower to dodge BEAM's per-function instruction limit). {:arrlit,_}/{:objlit,_} tag
  # the containers; every primitive (float/string/bool/:null/{:bigint}/:undefined) passes through unchanged.
  def deep_lit({:arrlit, els}), do: avec(Enum.map(els, &deep_lit/1))
  def deep_lit({:objlit, pairs}), do: cell_new(Enum.map(pairs, fn {k, v} -> {k, deep_lit(v)} end))
  def deep_lit(v), do: v

  @doc "Flatten a list of arrays into one array (partial-folded array literals concat their segments in order)."
  def aconcat(arrs), do: avec(Enum.flat_map(arrs, &al/1))

  @doc "Array literal WITH spread elements: parts are `{:one, v}` | `{:spread, iterable}`."
  def aspread(parts) do
    avec(Enum.flat_map(parts, fn {:spread, v} -> iter(v); {:one, v} -> [v] end))
  end

  @doc "Flatten call arguments with spread elements into a plain args list (`f(...xs, y)`)."
  def spread_args(parts), do: Enum.flat_map(parts, fn {:spread, v} -> iter(v); {:one, v} -> [v] end)

  @doc "Array rest binding `[a, ...rest] = arr` — the elements from index `from` onward as a new array."
  def arest({t, _} = a, from) when t in [:arr, :al], do: avec(Enum.drop(al(a), from))
  def arest(_other, _from), do: avec([])

  @doc "Object rest binding `{a, ...rest} = o` — a new object of `o`'s own keys except the destructured ones."
  def orest(o, taken) do
    keep = okeys(o) |> Enum.reject(&(&1 in taken))
    cell_new(Enum.map(keep, fn k -> {k, oget(o, k)} end))
  end

  # ── regex as a CAPABILITY (backed by Elixir Regex, returns guest values, stays confined). A regex is a
  # guest-safe term `{:regex, compiled, source, flags}`; the guest can only pass it to the regex methods. ──
  @doc "Compile a guest regex. JS flags i/m/s/u/x map to Elixir opts; g is applied at match/replace time."
  def regex(source, flags) when is_binary(source) and not is_binary(flags), do: regex(source, "")

  def regex(source, flags) when is_binary(source) do
    # JS-invalid patterns/flags throw a catchable SyntaxError (test262 S15.10.1). The validator is
    # CONSERVATIVE: it flags only shapes that are definitely invalid in JS (leading/stacked quantifiers,
    # unterminated group/class, unmatched paren, bad flags) — anything it is unsure about still compiles,
    # and a PCRE-only compile failure keeps the silent never-match fallback (JS-valid PCRE-invalid patterns
    # like surrogate ranges must not start throwing).
    case js_pattern_error(source) do
      nil -> :ok
      msg -> throw({:gg_throw, mk_error("SyntaxError", "Invalid regular expression: /" <> source <> "/: " <> msg)})
    end

    if flags != (flags |> String.graphemes() |> Enum.uniq() |> Enum.join()) or
         not Enum.all?(String.graphemes(flags), &(&1 in ~w(d g i m s u v y))) do
      throw({:gg_throw, mk_error("SyntaxError", "Invalid regular expression flags: " <> flags)})
    end

    base = flags |> String.graphemes() |> Enum.filter(&(&1 in ~w(i m s u x))) |> Enum.join()

    # keep `source` (the JS-visible .source) as-is, but translate JS-only regex syntax before PCRE compile.
    pcre = js_re_to_pcre(source) |> rx_neutralize_surrogates()

    # `\x{…}` code-point escapes (from `\uXXXX` / large unicode ranges) require PCRE unicode mode; guest strings
    # are UTF-8. Without it, `\x{02C1}` fails "code point too large" — which silently broke terser's giant
    # UNICODE.ID_Start identifier regex → NO identifier tokenized.
    opts = if String.contains?(pcre, "\\x{") and not String.contains?(base, "u"), do: base <> "u", else: base

    case Regex.compile(pcre, opts) do
      {:ok, re} -> {:regex, re, source, flags}
      {:error, _} -> {:regex, ~r/(?!)/, source, flags}
    end
  end

  # PCRE rejects surrogate code points (0xD800–0xDFFF), which JS identifier regexes use in `\uD800-\uDBFF` ranges
  # / surrogate-pair sequences for astral chars. F2 strings are UTF-8 (astral = real code points, never
  # surrogates), so those constructs never match real text — replace each surrogate escape with U+FFFD so the
  # regex COMPILES and its BMP/ASCII part still matches. (Astral identifiers won't tokenize; acceptable.)
  defp rx_neutralize_surrogates(pcre), do: String.replace(pcre, ~r/\\x\{[Dd][89A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\}/, "\\x{FFFD}")

  # JS-only regex syntax → PCRE before compile:
  #  * `[^]` ("any char incl. newline") is an empty/invalid class in PCRE — rewrite to `[\s\S]`.
  #  * `\uXXXX` / `\u{X..}` code-point escapes — PCRE spells them `\x{...}` (a failed compile silently
  #    yields the never-match regex, which broke rollup's VALID_IDENTIFIER_REGEXP → `exports["y"]`).
  defp js_re_to_pcre(src), do: src |> String.replace("[^]", "[\\s\\S]") |> rx_u_escapes()

  defp rx_u_escapes(src), do: rx_u(src, [])
  defp rx_u(<<>>, acc), do: IO.iodata_to_binary(Enum.reverse(acc))
  defp rx_u(<<"\\\\", rest::binary>>, acc), do: rx_u(rest, ["\\\\" | acc])
  defp rx_u(<<"\\u{", rest::binary>>, acc) do
    case String.split(rest, "}", parts: 2) do
      [hex, tail] -> rx_u(tail, ["\\x{" <> hex <> "}" | acc])
      _ -> rx_u(rest, ["\\u{" | acc])
    end
  end
  defp rx_u(<<"\\x", a, b, rest::binary>>, acc)
       when (a in ?8..?9 or a in ?a..?f or a in ?A..?F) and (b in ?0..?9 or b in ?a..?f or b in ?A..?F) do
    # \xHH at/above 0x80: PCRE in byte mode matches the raw BYTE, but guest strings are UTF-8 — spell it
    # \x{HH} so the existing \x{ rule forces unicode mode and it matches the CODE POINT (\xFF = "ÿ").
    rx_u(rest, ["\\x{" <> <<a, b>> <> "}" | acc])
  end

  defp rx_u(<<"\\u", a, b, c, d, rest::binary>>, acc)
       when a in ?0..?9 or a in ?a..?f or a in ?A..?F do
    if Enum.all?([b, c, d], &(&1 in ?0..?9 or &1 in ?a..?f or &1 in ?A..?F)),
      do: rx_u(rest, ["\\x{" <> <<a, b, c, d>> <> "}" | acc]),
      else: rx_u(<<a, b, c, d, rest::binary>>, ["\\u" | acc])
  end
  defp rx_u(<<ch, rest::binary>>, acc), do: rx_u(rest, [<<ch>> | acc])

  # ── conservative JS pattern validator ──────────────────────────────────────────────────────────────────
  # A tiny scanner over the ORIGINAL JS pattern. Tracks whether the previous token can take a quantifier
  # (:atom = yes; :quant/:lazy = a second quantifier is invalid; :none/:open/:alt = nothing to repeat) plus
  # group depth and class state. Returns nil (ok) or an error message. Anything exotic falls through as :atom
  # so we never false-positive on it.
  defp js_pattern_error(src), do: jsre(src, :none, 0)

  defp jsre(<<>>, _prev, 0), do: nil
  defp jsre(<<>>, _prev, _depth), do: "Unterminated group"
  # escapes: backslash + anything is an atom (multi-char escapes like \u{..} continue as atoms harmlessly)
  defp jsre(<<?\\, _, rest::binary>>, _prev, d), do: jsre(rest, :atom, d)
  defp jsre(<<?\\>>, _prev, _d), do: "\\ at end of pattern"
  # character class: scan to the closing unescaped ] (']' first char is literal-in-class per JS)
  defp jsre(<<?[, rest::binary>>, _prev, d) do
    case jsre_class(rest) do
      {:ok, tail} -> jsre(tail, :atom, d)
      :unterminated -> "Unterminated character class"
      :bad_range -> "Range out of order in character class"
    end
  end
  # group open: consume the (?: (?= (?! (?<= (?<! (?<name> prefix so the '?' is not read as a quantifier
  defp jsre(<<?(, ??, ?<, c, rest::binary>>, _prev, d) when c in [?=, ?!], do: jsre(rest, :open, d + 1)
  defp jsre(<<?(, ??, ?<, rest::binary>>, _prev, d) do
    case String.split(rest, ">", parts: 2) do
      [_name, tail] -> jsre(tail, :open, d + 1)
      _ -> "Invalid named capture group"
    end
  end
  defp jsre(<<?(, ??, c, rest::binary>>, _prev, d) when c in [?:, ?=, ?!], do: jsre(rest, :open, d + 1)
  defp jsre(<<?(, rest::binary>>, _prev, d), do: jsre(rest, :open, d + 1)
  defp jsre(<<?), rest::binary>>, _prev, d) when d > 0, do: jsre(rest, :atom, d - 1)
  defp jsre(<<?), _rest::binary>>, _prev, _d), do: "Unmatched ')'"
  defp jsre(<<?|, rest::binary>>, _prev, d), do: jsre(rest, :alt, d)
  # * and + : need a preceding atom; never valid after another quantifier
  defp jsre(<<c, rest::binary>>, prev, d) when c in [?*, ?+] do
    if prev == :atom, do: jsre(rest, :quant, d), else: "Nothing to repeat"
  end
  # ? : quantifier after an atom, LAZY modifier after a quantifier (a*?), otherwise invalid
  defp jsre(<<??, rest::binary>>, prev, d) do
    case prev do
      :atom -> jsre(rest, :quant, d)
      :quant -> jsre(rest, :lazy, d)
      _ -> "Nothing to repeat"
    end
  end
  # {n} / {n,} / {n,m} quantifier shape; a non-quantifier '{' is a literal atom (Annex B)
  defp jsre(<<?{, rest::binary>> = all, prev, d) do
    case jsre_braces(rest) do
      :bad_quant ->
        "numbers out of order in {} quantifier"

      {:quant, tail} ->
        case prev do
          :atom -> jsre(tail, :quant, d)
          p when p in [:quant, :lazy] -> "Nothing to repeat"
          _ -> "Nothing to repeat"
        end

      :literal ->
        <<_, tail::binary>> = all
        jsre(tail, :atom, d)
    end
  end
  defp jsre(<<_, rest::binary>>, _prev, d), do: jsre(rest, :atom, d)

  defp jsre_class(<<?\\, _, rest::binary>>), do: jsre_class(rest)
  defp jsre_class(<<?], rest::binary>>), do: {:ok, rest}
  # literal range a-b with both endpoints plain (non-escape) chars: out of order => SyntaxError. `-` before
  # `]` or next to an escape stays literal/unchecked (conservative).
  defp jsre_class(<<lo, ?-, hi, rest::binary>>) when lo != ?\\ and hi != ?\\ and hi != ?] do
    if lo > hi, do: :bad_range, else: jsre_class(rest)
  end
  defp jsre_class(<<_, rest::binary>>), do: jsre_class(rest)
  defp jsre_class(<<>>), do: :unterminated

  # parse {digits(,digits?)?} — returns {:quant, tail} when it is a real quantifier shape, else :literal
  defp jsre_braces(bin) do
    case Integer.parse(bin) do
      {_n, <<?}, tail::binary>>} -> {:quant, tail}
      {_n, <<?,, ?}, tail::binary>>} -> {:quant, tail}
      {n, <<?,, rest2::binary>>} ->
        case Integer.parse(rest2) do
          # {min,max} with max < min is a SyntaxError (surfaced via the :bad_quant marker)
          {m, <<?}, _tail::binary>>} when m < n -> :bad_quant
          {_m, <<?}, tail::binary>>} -> {:quant, tail}
          _ -> :literal
        end
      _ -> :literal
    end
  end

  # `new RegExp(re)` / `new RegExp(re, "g")` — rebuild from the source regex; explicit flags override.
  def regex({:regex, _, src, oldflags}, flags), do: regex(src, (if flags in ["", :undefined], do: oldflags, else: flags))
  def regex(_source, _flags), do: {:regex, ~r/(?!)/, "", ""}

  defp global?({:regex, _re, _src, flags}), do: String.contains?(flags, "g")

  # string × regex methods (marked's hot surface): replace/match/split/test/exec
  # function replacement: Elixir's Regex.replace passes captures as SEPARATE args (variable arity), so drive
  # it with Regex.scan and splice manually — the JS callback gets (fullMatch, ...groups).
  def method(s, "replace", [{:regex, re, _, _} = rx, f]) when is_binary(s) and (elem(f, 0) == :fn or elem(f, 0) == :host) do
    idxs = Regex.scan(re, s, return: :index)
    idxs = if global?(rx), do: idxs, else: Enum.take(idxs, 1)
    # JS replacer args are (match, p1..pN, offset, string) with N = the PATTERN's group count; Regex.scan
    # truncates trailing unmatched optional groups, which would shift offset into a group slot — pad them.
    ngroups = rx_group_count(re)

    {chunks, last} =
      Enum.reduce(idxs, {[], 0}, fn caps, {acc, pos} ->
        [{ms, ml} | _] = caps
        [full | groups] = Enum.map(caps, fn {i, l} -> if i < 0, do: :undefined, else: binary_part(s, i, l) end)
        groups = groups ++ List.duplicate(:undefined, max(ngroups - length(groups), 0))
        repl = to_str(call(f, [full | groups] ++ [ms * 1.0, s]))
        {[acc, binary_part(s, pos, ms - pos), repl], ms + ml}
      end)

    IO.iodata_to_binary([chunks, binary_part(s, last, byte_size(s) - last)])
  end

  # capture-group count of a compiled regex: '(' openers that are real groups (not (?: (?= (?! (?<= (?<!),
  # counting named groups (?<name>...), skipping escaped parens and char classes.
  defp rx_group_count(re), do: rx_gc(Regex.source(re), false, 0)
  defp rx_gc(<<>>, _cc, n), do: n
  defp rx_gc(<<"\\", _, rest::binary>>, cc, n), do: rx_gc(rest, cc, n)
  defp rx_gc(<<"[", rest::binary>>, false, n), do: rx_gc(rest, true, n)
  defp rx_gc(<<"]", rest::binary>>, true, n), do: rx_gc(rest, false, n)
  defp rx_gc(<<"(?<", c, rest::binary>>, false, n) when c not in [?=, ?!], do: rx_gc(rest, false, n + 1)
  defp rx_gc(<<"(?", rest::binary>>, false, n), do: rx_gc(rest, false, n)
  defp rx_gc(<<"(", rest::binary>>, false, n), do: rx_gc(rest, false, n + 1)
  defp rx_gc(<<_, rest::binary>>, cc, n), do: rx_gc(rest, cc, n)

  def method(s, "replace", [{:regex, re, _, _} = rx, repl]) when is_binary(s) do
    Regex.replace(re, s, regex_replacement(repl), global: global?(rx))
  end

  def method(s, "replace", [pat, repl]) when is_binary(s) and is_binary(pat) do
    # string pattern: replace first occurrence
    case :binary.match(s, pat) do
      {pos, len} -> binary_part(s, 0, pos) <> to_str(apply_str_repl(repl, pat)) <> binary_part(s, pos + len, byte_size(s) - pos - len)
      :nomatch -> s
    end
  end

  def method(s, "match", [{:regex, re, _, _} = rx]) when is_binary(s) do
    if global?(rx) do
      case Regex.scan(re, s, capture: :first) |> List.flatten() do
        [] -> :null
        list -> avec(list)
      end
    else
      # a non-global match result carries `.index` (match position) and `.input` (the subject) — like exec.
      case Regex.run(re, s, return: :index) do
        # spec: String.prototype.match returns `null` on no-match (NOT undefined) — `x.match(re) === null`
        # guards are load-bearing (marked's fences: `null === (u = t.match(re)) ? n : u[1]`).
        nil ->
          :null

        [{ms, _} | _] = idxs ->
          re_setlast(idxs, s)
          caps = Enum.map(idxs, fn {i, l} -> if i < 0, do: :undefined, else: binary_part(s, i, l) end)
          avec(caps, match_props(re, s, ms))
      end
    end
  end

  # `.index` / `.input`, plus `.groups` (an object of named captures) when the pattern has `(?<name>…)`; else
  # `.groups` is absent → undefined, per spec.
  defp match_props(re, s, ms) do
    base = %{"index" => ms * 1.0, "input" => s}

    case Regex.names(re) do
      [] ->
        base

      names ->
        nc = Regex.named_captures(re, s) || %{}
        Map.put(base, "groups", cell_new(Enum.map(names, fn n -> {n, Map.get(nc, n) || :undefined} end)))
    end
  end

  def method(s, "split", [{:regex, re, _, _}]) when is_binary(s), do: avec(Regex.split(re, s))
  def method(s, "search", [{:regex, re, _, _}]) when is_binary(s) do
    case Regex.run(re, s, return: :index) do
      [{pos, _} | _] -> pos * 1.0
      _ -> -1.0
    end
  end

  # `lastIndex` state is per-regex-term (structural key), so a global/sticky regex resumes across exec/test
  # calls (marked's reflinkSearch mask loop + emStrong rDelim loop rely on this).
  defp relast_get(r), do: Process.get({:gg_relast, r}, 0)
  defp relast_set(r, n), do: Process.put({:gg_relast, r}, max(n, 0))

  # Legacy static `RegExp.$1`…`RegExp.$9`: after any successful match, store the capture groups so
  # `RegExp.$1` reads group 1 (linkedom's DOCTYPE parse: `const {$1, $4, $6} = RegExp`).
  defp re_setlast(idxs, str) do
    caps = Enum.map(idxs, fn {i, l} -> if i < 0, do: "", else: binary_part(str, i, l) end)
    Process.put(:gg_re_lastmatch, caps)
    idxs
  end

  def method({:regex, re, _src, flags} = r, "test", [s | _]) do
    str = to_str(s)
    global = String.contains?(flags, "g") or String.contains?(flags, "y")
    start = if global, do: relast_get(r), else: 0

    case start <= byte_size(str) && Regex.run(re, str, offset: start, return: :index) do
      [{ms, ml} | _] = idxs -> re_setlast(idxs, str); (if global, do: relast_set(r, ms + ml)); true
      _ -> (if global, do: relast_set(r, 0)); false
    end
  end

  # JS exec: stateful for global/sticky regexes (resumes from lastIndex, advances it, resets on miss). The
  # result array carries `.index`/`.input`. Returns `:null` on no match (marked's loops check `!= null`).
  def method({:regex, re, _src, flags} = r, "exec", [s | _]) do
    str = to_str(s)
    global = String.contains?(flags, "g") or String.contains?(flags, "y")
    start = if global, do: relast_get(r), else: 0

    case start <= byte_size(str) && Regex.run(re, str, offset: start, return: :index) do
      [{ms, ml} | _] = idxs ->
        re_setlast(idxs, str)
        caps = Enum.map(idxs, fn {i, l} -> if i < 0, do: :undefined, else: binary_part(str, i, l) end)
        if global, do: relast_set(r, ms + ml)
        avec(caps, match_props(re, str, ms))

      _ ->
        (if global, do: relast_set(r, 0)); :null
    end
  end

  # a function replacement `.replace(re, fn)` — Elixir passes the whole match + captures as separate args.
  defp regex_replacement({:fn, _} = f), do: fn full, caps -> to_str(call(f, [full | (caps || [])])) end
  defp regex_replacement({:host, _} = f), do: fn full, caps -> to_str(call(f, [full | (caps || [])])) end
  defp regex_replacement(repl), do: js_repl_to_elixir(to_str(repl))

  # JS replacement templates: $1..$9 -> \1, $& -> \0, $$ -> $
  defp js_repl_to_elixir(t) do
    t
    |> String.replace("$$", "\x00DOLLAR\x00")
    |> String.replace(~r/\$(\d)/, "\\\\\\1")
    |> String.replace("$&", "\\0")
    |> String.replace("\x00DOLLAR\x00", "$")
  end

  defp apply_str_repl({:fn, _} = f, matched), do: call(f, [matched])
  defp apply_str_repl(repl, _matched), do: repl

  @doc """
  Confined METHOD dispatch: `recv.name(args)`. The dispatch table IS the builtin surface — a name that
  doesn't resolve for the receiver type is a guest `:undefined` (never a host reach). Mutating array methods
  (push/pop/…) return `{new_receiver, result}` so the lowering can rebind an identifier receiver.
  """
  # Set
  def method({:set, id} = st, "add", [v | _]), do: (Process.put({:gg_set, id}, Enum.uniq(set_list(st) ++ [v])); st)
  def method({:set, _} = st, "has", [v | _]), do: Enum.any?(set_list(st), &(&1 === v))
  def method({:set, id} = st, "delete", [v | _]), do: (had = method(st, "has", [v]); Process.put({:gg_set, id}, Enum.reject(set_list(st), &(&1 === v))); had)
  def method({:set, id}, "clear", _), do: (Process.put({:gg_set, id}, []); :undefined)
  def method({:set, _} = st, "forEach", [f | _]), do: (Enum.each(set_list(st), fn v -> call(f, [v, v]) end); :undefined)
  # Map
  def method({:map, _} = mp, "get", [k | _]), do: (case List.keyfind(map_pairs(mp), k, 0) do {_, v} -> v; _ -> :undefined end)
  def method({:map, id} = mp, "set", [k, v | _]), do: (Process.put({:gg_map, id}, List.keystore(map_pairs(mp), k, 0, {k, v})); mp)
  def method({:map, _} = mp, "has", [k | _]), do: List.keymember?(map_pairs(mp), k, 0)
  def method({:map, id} = mp, "delete", [k | _]), do: (had = method(mp, "has", [k]); Process.put({:gg_map, id}, List.keydelete(map_pairs(mp), k, 0)); had)
  def method({:map, id}, "clear", _), do: (Process.put({:gg_map, id}, []); :undefined)
  def method({:map, _} = mp, "forEach", [f | _]), do: (Enum.each(map_pairs(mp), fn {k, v} -> call(f, [v, k]) end); :undefined)
  def method({:map, _} = mp, "keys", _), do: avec(Enum.map(map_pairs(mp), &elem(&1, 0)))
  def method({:map, _} = mp, "values", _), do: avec(Enum.map(map_pairs(mp), &elem(&1, 1)))
  def method({:map, _} = mp, "entries", _), do: avec(Enum.map(map_pairs(mp), fn {k, v} -> avec([k, v]) end))

  # ── Promises: synchronous/eager model. No event loop — resolve/reject settle immediately and .then runs its
  # callback right away on an already-settled promise (a pending promise queues callbacks, run on settle). This
  # covers rollup's load-time Promise.resolve().then(...) deferral idioms; strict microtask ordering is a later
  # rung if byte-identical output needs it.
  def method({:promise, _} = p, "then", [onF | rest]), do: prom_then(p, onF, List.first(rest) || :undefined)
  def method({:promise, _} = p, "catch", [onR | _]), do: prom_then(p, :undefined, onR)
  def method({:promise, _} = p, "finally", [onFin | _]) do
    f = closure(fn _t, a -> (invoke_if(onFin, []); List.first(a) || :undefined) end)
    r = closure(fn _t, a -> (invoke_if(onFin, []); throw_val(List.first(a) || :undefined)) end)
    prom_then(p, f, r)
  end
  # a computed-member CALL `arr[i](args)` / `ta[i](args)` — the callee is the element (a function), invoked
  # with `this` = the container (rollup: `nodeConverters[nodeType](position, buffer)`).
  # generator/iterator protocol: next() advances the (eagerly-collected) values, return()/throw() terminate it.
  def method({:geniter, id}, "next", _args) do
    {list, pos} = Process.get({:gg_geniter, id}, {[], 0})

    if pos < length(list) do
      Process.put({:gg_geniter, id}, {list, pos + 1})
      iter_result(Enum.at(list, pos), false)
    else
      iter_result(:undefined, true)
    end
  end

  def method({:geniter, id}, "return", args) do
    Process.put({:gg_geniter, id}, {[], 0})
    iter_result(List.first(args) || :undefined, true)
  end

  def method({:geniter, _}, "throw", args), do: throw({:gg_throw, List.first(args) || :undefined})
  # `it[Symbol.iterator]()` (computed-method-call dispatch) returns the iterator itself.
  def method({:geniter, _} = g, {:symbol, "@@iterator", _}, _), do: g

  def method({t, _} = a, k, args) when t in [:arr, :al] and is_number(k), do: invoke(oget(a, k), a, args)
  def method({:ta, _, _, _, _} = ta, k, args) when is_number(k), do: invoke(oget(ta, k), ta, args)

  # ── all array methods on a mutable reference: mutating ops write the table in place (aliases share); pure
  # ops return a NEW array. ──
  def method({t, _} = a, name, args) when t in [:arr, :al] do
    list = al(a)
    a0 = List.first(args)
    arr_method(a, list, name, a0, args)
  end

  def method(s, "charCodeAt", [i | _]) when is_binary(s) do
    idx = trunc(i)
    # out-of-range charCodeAt is NaN (not undefined) per spec.
    cond do
      idx < 0 -> :nan
      ascii?(s) -> (if idx < byte_size(s), do: :binary.at(s, idx) * 1.0, else: :nan)
      true -> (case Enum.at(safe_charlist(s), idx) do nil -> :nan; cp -> cp * 1.0 end)
    end
  end

  def method(s, "length", _) when is_binary(s), do: str_len(s) * 1.0
  def method(s, "toUpperCase", _) when is_binary(s), do: String.upcase(s)
  def method(s, "toLowerCase", _) when is_binary(s), do: String.downcase(s)
  def method(s, "slice", [a | rest]) when is_binary(s), do: str_slice(s, a, rest)
  def method(s, "indexOf", [sub | rest]) when is_binary(s) do
    # honor the optional fromIndex (JS `str.indexOf(sub, from)`); acorn's regex-flag validation relies on it.
    from = case rest do [f | _] when is_number(f) -> min(max(trunc(f), 0), byte_size(s)); _ -> 0 end
    scope = binary_part(s, from, byte_size(s) - from)

    case :binary.match(scope, to_str(sub)) do
      {pos, _} -> (pos + from) * 1.0
      :nomatch -> -1.0
    end
  end

  def method(s, "split", [sep | _]) when is_binary(s), do: avec(String.split(s, to_str(sep)))
  def method(s, "trim", _) when is_binary(s), do: String.trim(s)
  def method(s, "trimStart", _) when is_binary(s), do: String.trim_leading(s)
  def method(s, "trimLeft", _) when is_binary(s), do: String.trim_leading(s)
  def method(s, "trimRight", _) when is_binary(s), do: String.trim_trailing(s)
  def method(s, "trimEnd", _) when is_binary(s), do: String.trim_trailing(s)
  def method(s, "substring", [a | rest]) when is_binary(s), do: str_substring(s, a, rest)
  def method(s, "substr", [a | rest]) when is_binary(s), do: str_slice(s, a, (case rest do [l | _] -> [a + l]; _ -> [] end))
  def method(s, "charAt", [i | _]) when is_binary(s), do: (if oget(s, i * 1) == :undefined, do: "", else: oget(s, i * 1))
  def method(s, "charAt", _) when is_binary(s), do: binary_part(s, 0, min(1, byte_size(s)))
  def method(s, "at", [i | _]) when is_binary(s) do
    # index by CODE UNIT, not byte — `"café".at(-1)` is "é", not a raw UTF-8 byte.
    len = str_len(s)
    idx = trunc(i)
    idx = if idx < 0, do: len + idx, else: idx
    if idx >= 0 and idx < len, do: (String.at(s, idx) || :undefined), else: :undefined
  end
  def method(s, "repeat", [n | _]) when is_binary(s) and is_number(n), do: String.duplicate(s, min(max(trunc(n), 0), 1_000_000))
  def method(s, "repeat", _) when is_binary(s), do: ""
  def method(s, "padStart", [len | rest]) when is_binary(s), do: str_pad(s, len, rest, :leading)
  def method(s, "padEnd", [len | rest]) when is_binary(s), do: str_pad(s, len, rest, :trailing)
  # matchAll: every match as an exec-style entry (captures + index/input props) in an array — our for-of and
  # spread iterate arrays, which covers the iterator protocol uses (svelte scans templates with it).
  def method(s, "matchAll", [{:regex, re, _src, _flags} | _]) when is_binary(s) do
    Regex.scan(re, s, return: :index)
    |> Enum.map(fn [{ms, ml} | groups] ->
      caps = Enum.map([{ms, ml} | groups], fn {i, l} -> if i < 0, do: :undefined, else: binary_part(s, i, l) end)
      avec(caps, %{"index" => ms * 1.0, "input" => s})
    end)
    |> avec()
  end

  # startsWith/endsWith take an optional POSITION argument (svelte's template matcher is
  # `template.startsWith("each", index)` — ignoring it made every block keyword miss).
  def method(s, "startsWith", [p | rest]) when is_binary(s) do
    case rest do
      [pos | _] when is_number(pos) -> String.starts_with?(str_slice_from(s, trunc(pos)), to_str(p))
      _ -> String.starts_with?(s, to_str(p))
    end
  end

  def method(s, "endsWith", [p | rest]) when is_binary(s) do
    case rest do
      [epos | _] when is_number(epos) -> String.ends_with?(str_slice_to(s, trunc(epos)), to_str(p))
      _ -> String.ends_with?(s, to_str(p))
    end
  end

  defp str_slice_from(s, pos) when pos <= 0, do: s
  defp str_slice_from(s, pos), do: (case String.split_at(s, pos) do {_, tail} -> tail end)
  defp str_slice_to(s, epos), do: (case String.split_at(s, max(epos, 0)) do {head, _} -> head end)
  def method(s, "includes", [p | _]) when is_binary(s), do: String.contains?(s, to_str(p))
  def method(s, "replaceAll", [p, r | _]) when is_binary(s) and is_binary(p), do: String.replace(s, p, to_str(r))
  def method(s, "concat", args) when is_binary(s), do: s <> (args |> Enum.map(&to_str/1) |> Enum.join())
  def method(s, "lastIndexOf", [sub | _]) when is_binary(s) do
    parts = :binary.matches(s, to_str(sub))
    case List.last(parts) do {pos, _} -> pos * 1.0; _ -> -1.0 end
  end
  def method(s, m, _) when is_binary(s) and m in ["toString", "valueOf", "normalize"], do: s
  # number toString with optional radix (acorn: `code.toString(16)`); JS emits lowercase digits.
  def method(n, "toString", args) when is_number(n) do
    case args do
      [r | _] when is_number(r) and r != 10.0 -> Integer.to_string(trunc(n), trunc(r)) |> String.downcase()
      _ -> to_str(n)
    end
  end
  def method(n, "valueOf", _) when is_number(n), do: n
  # bigint methods: (n).toString([radix]) and (n).valueOf().
  def method({:bigint, n}, "toString", args) do
    case args do
      [r | _] when is_number(r) and r != 10.0 -> Integer.to_string(n, trunc(r)) |> String.downcase()
      _ -> Integer.to_string(n)
    end
  end
  def method({:bigint, _} = b, "valueOf", _), do: b
  def method(s, "codePointAt", [i | _]) when is_binary(s) do
    case oget(s, i * 1) do c when is_binary(c) -> (:binary.first(c)) * 1.0; _ -> :undefined end
  end

  # array-method dispatch on the deref'd `list`; mutating cases `aset_l(a, …)` write back in place.
  defp arr_flat(list), do: Enum.flat_map(list, fn x -> if match?({:arr, _}, x), do: al(x), else: [x] end)

  defp arr_method(a, list, name, a0, args) do
    case name do
      "push" -> aset_l(a, list ++ args); (length(list) + length(args)) * 1.0
      "pop" -> case list do
                 [] -> :undefined
                 _ -> {init, [last]} = Enum.split(list, -1); aset_l(a, init); last
               end
      "shift" -> case list do [] -> :undefined; [h | t] -> aset_l(a, t); h end
      "unshift" -> aset_l(a, args ++ list); (length(list) + length(args)) * 1.0
      "join" -> sep = if a0, do: to_str(a0), else: ","; list |> Enum.map(fn v -> if v in [:undefined, :null], do: "", else: to_str(v) end) |> Enum.join(sep)
      "indexOf" -> (Enum.find_index(list, &(&1 === a0)) || -1) * 1.0
      "lastIndexOf" -> idx = list |> Enum.reverse() |> Enum.find_index(&(&1 === a0)); if idx, do: (length(list) - 1 - idx) * 1.0, else: -1.0
      "includes" -> Enum.any?(list, &(&1 === a0))
      "slice" -> avec(slice_list(list, a0 || 0.0, Enum.drop(args, 1)))
      # typed-array subarray: a view expressed as a fresh backing array (sufficient for read/decode use).
      "subarray" -> avec(slice_list(list, a0 || 0.0, Enum.drop(args, 1)))
      # typed-array bulk set: write src elements starting at offset.
      "set" -> src = (case a0 do {:arr,_} -> al(a0); _ -> [] end); off = trunc(to_number(Enum.at(args, 1) || 0.0)); aset_l(a, ta_set(list, src, off)); :undefined
      "concat" -> avec(list ++ arr_flat(args))
      "flat" -> avec(arr_flat(list))
      "map" -> avec(Enum.with_index(list) |> Enum.map(fn {v, i} -> call(a0, [v, i * 1.0, a]) end))
      # flatMap: map then flatten ONE level (svelte's codegen builds statement lists this way).
      "flatMap" -> avec(Enum.with_index(list) |> Enum.flat_map(fn {v, i} -> (r = call(a0, [v, i * 1.0, a]); case r do {:arr, _} -> al(r); _ -> [r] end) end))
      "filter" -> avec(Enum.filter(list, fn v -> truthy(call(a0, [v])) end))
      "forEach" -> Enum.with_index(list) |> Enum.each(fn {v, i} -> call(a0, [v, i * 1.0, a]) end); :undefined
      "find" -> Enum.find(list, :undefined, fn v -> truthy(call(a0, [v])) end)
      "findIndex" -> (Enum.find_index(list, fn v -> truthy(call(a0, [v])) end) || -1) * 1.0
      "some" -> Enum.any?(list, fn v -> truthy(call(a0, [v])) end)
      "every" -> Enum.all?(list, fn v -> truthy(call(a0, [v])) end)
      "reduce" -> arr_reduce(list, args)
      "reduceRight" -> Enum.reduce(Enum.reverse(list), (if length(args) > 1, do: Enum.at(args, 1), else: :undefined), fn v, acc -> call(a0, [acc, v]) end)
      "sort" -> cmp = if match?({:fn, _}, a0), do: a0, else: nil
                sorted = if cmp, do: Enum.sort(list, fn x, y -> num(call(cmp, [x, y])) <= 0 end), else: Enum.sort_by(list, &to_str/1)
                aset_l(a, sorted); a
      "reverse" -> aset_l(a, Enum.reverse(list)); a
      "fill" -> aset_l(a, Enum.map(list, fn _ -> a0 end)); a
      "at" -> idx = trunc(num(a0)); idx = if idx < 0, do: length(list) + idx, else: idx; Enum.at(list, idx, :undefined)
      "splice" -> arr_splice(a, list, args)
      # iterator methods — returned as arrays (for-of over an array works; strict iterator identity unneeded).
      "entries" -> avec(list |> Enum.with_index() |> Enum.map(fn {v, i} -> avec([i * 1.0, v]) end))
      "keys" -> avec(Enum.map(0..max(length(list) - 1, -1)//1, &(&1 * 1.0)))
      "values" -> avec(list)
      m when m in ["toString", "valueOf"] -> list |> Enum.map(&to_str/1) |> Enum.join(",")
      _ ->
        # a function-valued named property (rare): call it; else it is not a function.
        case Map.get(ap(a), name, :undefined) do
          {:fn, _} = f -> invoke(f, a, args)
          _ -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP arrmeth #{inspect(name)}"); guest_error("not a function")
        end
    end
  end

  defp arr_reduce(list, [f | rest]) do
    case rest do
      [init | _] -> Enum.reduce(Enum.with_index(list), init, fn {v, i}, acc -> call(f, [acc, v, i * 1.0]) end)
      [] ->
        case list do
          [] -> guest_error("reduce of empty array with no initial value")
          [h | t] -> Enum.reduce(Enum.with_index(t, 1), h, fn {v, i}, acc -> call(f, [acc, v, i * 1.0]) end)
        end
    end
  end

  # arr.splice(start, deleteCount, ...items) — mutate in place, return the removed elements as a new array.
  defp arr_splice(a, list, args) do
    len = length(list)
    start = trunc(num(List.first(args) || 0.0))
    start = if start < 0, do: max(len + start, 0), else: min(start, len)
    dcount = case args do [_, d | _] -> max(trunc(num(d)), 0); _ -> len - start end
    items = Enum.drop(args, 2)
    removed = Enum.slice(list, start, dcount)
    aset_l(a, Enum.take(list, start) ++ items ++ Enum.drop(list, start + dcount))
    avec(removed)
  end

  def method({keys, map}, "hasOwnProperty", [k | _]) when is_map(map), do: Map.has_key?(map, key_str(k))
  def method({_keys, map}, "propertyIsEnumerable", [k | _]) when is_map(map), do: Map.has_key?(map, key_str(k))

  # user object with a FUNCTION-valued property: `o.f(args)` calls the stored closure (no `this` binding yet).
  def method({_keys, map} = o, name, args) when is_map(map) do
    case oget(o, name) do
      {:fn, _} = f -> invoke(f, o, args)
      _ -> if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP objmeth #{inspect(name)}"); guest_error("not a function")
    end
  end

  # a mutable-cell instance: `hasOwnProperty`, else a function-valued property is a method with this=the cell.
  def method({:cell, _} = c, "hasOwnProperty", [k | _]), do: Map.has_key?(cell_read(c) |> elem(1), key_str(k))
  # cell own props are enumerable in F2 (no per-property non-enumerable flag for cells yet) — used by test262's
  # propertyHelper `Function.prototype.call.bind(Object.prototype.propertyIsEnumerable)`.
  def method({:cell, _} = c, "propertyIsEnumerable", [k | _]), do: prop_is_enum(c, k)
  # function objects: hasOwnProperty / propertyIsEnumerable. `.name`/`.length` are own but NON-enumerable.
  def method({:fn, _} = f, "hasOwnProperty", [k | _]), do: has_own(f, k)
  def method({:fn, _} = f, "propertyIsEnumerable", [k | _]), do: prop_is_enum(f, k)

  # is `k` an ENUMERABLE own property of `o`? Function `name`/`length`/`prototype` are own but non-enumerable;
  # for other object kinds F2 has no per-property enumerable flag yet, so any own property is enumerable.
  # which built-in prototype "owns" a value (isPrototypeOf tag match)
  defp proto_of_tag({:regex, _, _, _}), do: "RegExp"
  defp proto_of_tag({t, _}) when t in [:arr, :al], do: "Array"
  defp proto_of_tag({:fn, _}), do: "Function"
  defp proto_of_tag(v) when is_binary(v), do: "String"
  defp proto_of_tag(v) when is_number(v), do: "Number"
  defp proto_of_tag(v) when is_boolean(v), do: "Boolean"
  defp proto_of_tag({:date, _}), do: "Date"
  defp proto_of_tag({:set, _}), do: "Set"
  defp proto_of_tag({:map, _}), do: "Map"
  defp proto_of_tag({:promise, _}), do: "Promise"
  defp proto_of_tag(_), do: nil

  defp prop_is_enum({:fn, _} = o, k), do: (ks = key_str(k); has_own(o, ks) and ks not in ["name", "length", "prototype"])
  defp prop_is_enum(o, k), do: (ks = key_str(k); has_own(o, ks) and prop_enumerable?(o, ks))

  def method({:cell, id} = c, name, args) do
    coll = Process.get({:gg_cellcoll, id})
    arr = Process.get({:gg_cellarr, id})
    cond do
      match?({:fn, _}, oget(c, name)) -> invoke(oget(c, name), c, args)
      # a cell backed by a Set/Map (class extends Set/Map): delegate collection methods. Mutators return the
      # instance (this) for chaining; queries return the result.
      coll != nil and name in ["add", "set"] -> method(coll, name, args); c
      coll != nil and name in ["has", "get", "delete", "clear", "forEach", "keys", "values", "entries"] -> method(coll, name, args)
      # a cell backed by a real array (class extends Array — linkedom's NodeList/HTMLCollection): delegate array
      # methods to the backing array, which mutates in place, so this.push(x)/this.splice(…) grow the instance.
      arr != nil and name in @arr_methods -> method(arr, name, args)
      true ->
        if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP cellmeth #{inspect(name)} keys=#{inspect(okeys(c)) |> String.slice(0, 90)}")
        if System.get_env("GAPSOFT"), do: :undefined, else: guest_error("not a function")
    end
  end

  # ── Node Buffer: a raw byte buffer as {:bytes, binary}. Buffer.from(str[, enc]) / Buffer.from(byteArray).
  # Guest strings are already UTF-8 binaries, so utf-8 is identity; base64 decodes. Used by rollup's xxhash
  # (Buffer.from(id).toString("base64")) and the wasm-bridge base64 paths.
  def method({:global, "Buffer"}, "from", [data | rest]) do
    enc = List.first(rest)
    cond do
      enc == "base64" and is_binary(data) -> {:bytes, (case Base.decode64(data) do {:ok, b} -> b; _ -> "" end)}
      is_binary(data) -> {:bytes, data}
      match?({:bytes, _}, data) -> data
      match?({:arr, _}, data) -> {:bytes, al(data) |> Enum.map(&(trunc(to_number(&1)) |> Bitwise.band(0xFF))) |> :erlang.list_to_binary()}
      true -> {:bytes, ""}
    end
  end
  def method({:global, "Buffer"}, name, args) when name in ["alloc", "allocUnsafe"], do: (n = trunc(to_number(List.first(args) || 0.0)); {:bytes, :binary.copy(<<0>>, n)})
  def method({:global, "Buffer"}, "concat", [{:arr, _} = a | _]), do: {:bytes, al(a) |> Enum.map(fn {:bytes, b} -> b; b when is_binary(b) -> b; _ -> "" end) |> IO.iodata_to_binary()}
  def method({:global, "Buffer"}, "isBuffer", [x | _]), do: match?({:bytes, _}, x)

  # methods on a byte buffer value.
  def method({:bytes, b}, "toString", rest), do: (case List.first(rest) do "base64" -> Base.encode64(b); "hex" -> Base.encode16(b, case: :lower); _ -> b end)
  def method({:bytes, _} = bytes, "subarray", [a0 | rest]), do: (b = bytes_bin(bytes); s = trunc(to_number(a0)); e = (case rest do [e0 | _] -> trunc(to_number(e0)); _ -> byte_size(b) end); {:bytes, binary_part(b, s, max(min(e, byte_size(b)) - s, 0))})
  def method({:bytes, _} = bytes, "slice", args), do: method(bytes, "subarray", args)

  # typed-array methods
  def method({:ta, kind, id, off, len} = ta, "subarray", args) do
    a = trunc(to_number(List.first(args) || 0.0)); a = if a < 0, do: max(len + a, 0), else: min(a, len)
    e = case Enum.at(args, 1) do nil -> len; x -> (xe = trunc(to_number(x)); if xe < 0, do: max(len + xe, 0), else: min(xe, len)) end
    _ = id; _ = off
    {:ta, kind, id, off + a * ta_size(kind), max(e - a, 0)}
  end
  def method({:ta, kind, _, _, len} = ta, "slice", args) do
    a = trunc(to_number(List.first(args) || 0.0)); a = if a < 0, do: max(len + a, 0), else: min(a, len)
    e = case Enum.at(args, 1) do nil -> len; x -> (xe = trunc(to_number(x)); if xe < 0, do: max(len + xe, 0), else: min(xe, len)) end
    ta_from_elems(kind, Enum.slice(ta_elems(ta), a, max(e - a, 0)))
  end
  def method({:ta, _, _, _, _} = ta, "set", [src | rest]) do
    off = trunc(to_number(Enum.at(rest, 0) || 0.0))
    srcels = case src do {:ta, _, _, _, _} -> ta_elems(src); {:arr, _} -> al(src); _ -> [] end
    srcels |> Enum.with_index() |> Enum.each(fn {v, i} -> ta_set(ta, off + i, v) end)
    :undefined
  end
  def method({:ta, _, _, _, len} = ta, "fill", [v | _]), do: (Enum.each(0..(len - 1)//1, fn i -> ta_set(ta, i, v) end); ta)

  # DataView getX(byteOffset, littleEndian) / setX(byteOffset, value, littleEndian).
  def method({:dataview, id, base, _}, "get" <> kind, [pos | rest]) do
    le = List.first(rest) == true
    dv_get(dv_kind(kind), abuf_bin(id), base + trunc(to_number(pos)), le)
  end
  def method({:dataview, id, base, _}, "set" <> kind, [pos, v | rest]) do
    le = Enum.at(rest, 0) == true
    dv_set(id, dv_kind(kind), base + trunc(to_number(pos)), to_number(v), le)
    :undefined
  end
  def method({:ta, _, _, _, _} = ta, name, args) do
    # a named-property method (e.g. Object.assign'd convertString) is invoked; else an array-like method.
    f = Process.get({:gg_taprops, ta}, %{}) |> Map.get(name)
    if match?({:fn, _}, f) or match?({:host, _}, f), do: invoke(f, ta, args), else: method(avec(ta_elems(ta)), name, args)
  end

  # Date stub methods (deterministic; timing only).
  def method({:date, ms}, m, _) when m in ["getTime", "valueOf"], do: ms
  def method({:date, _}, "toISOString", _), do: "1970-01-01T00:00:00.000Z"
  def method({:date, _}, "toString", _), do: "Thu Jan 01 1970 00:00:00 GMT+0000"
  def method({:date, _}, m, _) when m in ["getFullYear"], do: 1970.0
  def method({:date, _}, _m, _), do: 0.0
  def method({:global, "Date"}, "now", _), do: 0.0

  # TextDecoder/TextEncoder: guest strings are UTF-8 binaries.
  def method({:textdecoder}, "decode", [b | _]), do: to_bin_bytes(b)
  def method({:textdecoder}, "decode", []), do: ""
  def method({:textencoder}, "encode", [s | _]), do: {:bytes, to_str(s)}
  def method({:textencoder}, "encode", []), do: {:bytes, ""}

  # a method call on a Proxy: get the (trapped) property, invoke with this=proxy.
  def method({:proxy, _, _} = px, name, args), do: invoke(oget(px, name), px, args)

  # `Builtin.call(this, …)` / `.apply(this, argsArray)` — a builtin used as a SUPERCLASS ctor: Lower rewrites
  # `super(...)` to `__ggsuper.call(this, ...)`, and the superclass may be a global (class X extends Set).
  # Route through invoke, which knows how to initialise a cell `this` from a builtin parent.
  def method({:global, _} = g, "call", [this | rest]), do: invoke(g, this, rest)
  def method({:global, _} = g, "apply", [this | rest]),
    do: invoke(g, this, (case rest do [{:arr, _} = av | _] -> al(av); _ -> [] end))

  # Reflect: the default-passthrough operations Proxy handlers delegate to.
  def method({:global, "Reflect"}, name, args), do: reflect_static(name, args)

  # ── global namespaces (Object/Array/Math/JSON/Number/String) — static methods + a few properties ──
  def method({:global, "Object"}, name, args), do: object_static(name, args)
  def method({:global, "Promise"}, name, args), do: promise_static(name, args)
  def method({:global, "Array"}, name, args), do: array_static(name, args)
  def method({:global, "Math"}, name, args), do: math_static(name, args)
  def method({:global, "JSON"}, "stringify", [v | rest]), do: json_stringify(v, rest)
  def method({:global, "JSON"}, "parse", [s | _]) when is_binary(s), do: json_parse(s)
  def method({:global, "Number"}, "isInteger", [x | _]), do: is_number(x) and trunc(x) == x
  def method({:global, "Number"}, "isSafeInteger", [x | _]), do: is_number(x) and trunc(x) == x and abs(x) <= 9_007_199_254_740_991
  def method({:global, "Number"}, "isNaN", [x | _]), do: to_number(x) == :nan
  def method({:global, "Number"}, "isFinite", [x | _]), do: is_number(x)
  def method({:global, "Number"}, "parseFloat", [x | _]), do: parse_float(x)
  def method({:global, "String"}, "fromCharCode", codes), do: codes |> Enum.map(&<<trunc(&1)::utf8>>) |> Enum.join()
  def method({:global, "String"}, "fromCodePoint", codes), do: codes |> Enum.map(&<<trunc(&1)::utf8>>) |> Enum.join()
  # Symbol.for(key): the GLOBAL symbol registered under `key` — same key ⇒ same symbol (stable id). Preact/React
  # use `Symbol.for('react.element')` etc. as type markers. (Direct-call path; `var f = Symbol.for` uses oget.)
  def method({:global, "Symbol"}, "for", [k | _]), do: (d = to_str(k); {:symbol, "for:" <> d, d})
  def method({:global, "Symbol"}, "keyFor", [{:symbol, _, d} | _]), do: d

  defp object_static("keys", [o | _]), do: avec(okeys(o))
  defp object_static("values", [o | _]), do: avec(Enum.map(okeys(o), &oget(o, &1)))
  defp object_static("entries", [o | _]), do: avec(Enum.map(okeys(o), fn k -> avec([k, oget(o, k)]) end))
  defp object_static("getOwnPropertyNames", [o | _]), do: avec(own_keys_all(o))
  defp object_static("assign", [target | sources]), do: Enum.reduce(sources, target, fn s, t -> Enum.reduce(okeys(s), t, fn k, acc -> oput(acc, k, oget(s, k)) end) end)
  # Object.create(proto[, props]): a fresh object whose prototype chain is `proto` (Babel `_inherits`), with
  # optional property descriptors (rollup: `Object.create(null, { [EntitiesKey]: { value: new Set() } })`).
  defp object_static("create", [proto | rest]) do
    c = cell_new([])
    if proto != :undefined and proto != :null do
      {:cell, id} = c
      Process.put({:gg_instproto, id}, proto)
    end
    case rest do
      [props | _] when props != :undefined and props != :null -> object_static("defineProperties", [c, props])
      _ -> c
    end
  end
  # freeze: every own property becomes non-writable + non-configurable (enumerability kept), and the object is
  # made non-extensible. seal: non-configurable only (values stay writable). preventExtensions: just the flag.
  defp object_static("freeze", [{:cell, _} = o | _]) do
    Enum.each(own_keys_all(o), fn k -> {_w, e, _c} = pattr_get(o, k); pattr_put(o, k, {false, e, false}) end)
    mark_nonextensible(o)
    o
  end
  defp object_static("freeze", [o | _]), do: o
  defp object_static("seal", [{:cell, _} = o | _]) do
    Enum.each(own_keys_all(o), fn k -> {w, e, _c} = pattr_get(o, k); pattr_put(o, k, {w, e, false}) end)
    mark_nonextensible(o)
    o
  end
  defp object_static("seal", [o | _]), do: o
  defp object_static("preventExtensions", [o | _]), do: (mark_nonextensible(o); o)
  defp object_static("isExtensible", [o | _]), do: extensible?(o)
  defp object_static("isFrozen", [{:cell, _} = o | _]),
    do: not extensible?(o) and Enum.all?(own_keys_all(o), fn k -> {w, _e, c} = pattr_get(o, k); not w and not c end)
  defp object_static("isFrozen", [_ | _]), do: true
  defp object_static("isSealed", [{:cell, _} = o | _]),
    do: not extensible?(o) and Enum.all?(own_keys_all(o), fn k -> {_w, _e, c} = pattr_get(o, k); not c end)
  defp object_static("isSealed", [_ | _]), do: true
  # defineProperty: set `value` if the descriptor carries one (Babel `_createClass` method attach); a
  # value-less descriptor (`{writable:false}` on `Ctor.prototype`) must NOT clobber the existing property. A
  # get/set descriptor installs an `{:accessor, get, set}`, MERGING with an existing accessor (separate
  # `defineProperty(o,k,{get})` then `{set}` calls build one accessor). Stored RAW so installing the setter
  # itself doesn't re-enter the write path.
  defp object_static("defineProperty", [o, k, desc | _]) do
    ks = to_str(k)
    existed = has_own(o, ks)
    # spec: for a NEW property an unspecified attribute defaults to false; redefining keeps current.
    {cw, ce, cc} = if existed, do: pattr_get(o, ks), else: {false, false, false}
    w = if has_own(desc, "writable"), do: truthy(oget(desc, "writable")), else: cw
    e = if has_own(desc, "enumerable"), do: truthy(oget(desc, "enumerable")), else: ce
    c = if has_own(desc, "configurable"), do: truthy(oget(desc, "configurable")), else: cc

    cond do
      has_own(desc, "value") ->
        # fn name/length: oput blocks plain writes (non-writable), but defineProperty may redefine them
        # (configurable) — install the override raw. Everything else keeps the oput route (setters, cells).
        case o do
          {:fn, _} when ks in ["name", "length"] -> raw_put(o, ks, oget(desc, "value"))
          _ -> oput(o, ks, oget(desc, "value"))
        end
        pattr_put(o, ks, {w, e, c})
        o

      has_own(desc, "get") or has_own(desc, "set") ->
        {cg, cs} =
          case raw_prop(o, ks) do
            {:accessor, g, s} -> {g, s}
            {:getter, g} -> {g, :undefined}
            _ -> {:undefined, :undefined}
          end

        ng = if has_own(desc, "get"), do: oget(desc, "get"), else: cg
        ns = if has_own(desc, "set"), do: oget(desc, "set"), else: cs
        raw_put(o, ks, {:accessor, ng, ns})
        pattr_put(o, ks, {w, e, c})
        o

      true ->
        o
    end
  end
  # Object.defineProperties(o, { k1: desc1, k2: desc2, … }) — acorn installs its getter properties this way.
  defp object_static("defineProperties", [o, descs | _]) do
    Enum.each(okeys(descs), fn k -> object_static("defineProperty", [o, k, oget(descs, k)]) end)
    o
  end

  # Reflect operations (Proxy default passthrough). Array/apply args come as a guest array.
  defp reflect_static("get", [t, k | _]), do: oget(t, k)
  defp reflect_static("set", [t, k, v | _]), do: (oput(t, k, v); true)
  defp reflect_static("has", [t, k | _]), do: has_own(t, k)
  defp reflect_static("ownKeys", [t | _]), do: avec(okeys(t))
  defp reflect_static("deleteProperty", [t, k | _]), do: odelete(t, k)
  defp reflect_static("getPrototypeOf", _), do: :null
  defp reflect_static("defineProperty", [t, k, d | _]), do: (object_static("defineProperty", [t, k, d]); true)
  defp reflect_static("construct", [ctor, a | _]), do: construct(ctor, arr_to_list(a))
  defp reflect_static("apply", [f, this, a | _]), do: invoke(f, this, arr_to_list(a))
  defp reflect_static(_, _), do: :undefined

  # delete a property from a cell (Reflect.deleteProperty / `delete o.k`). A non-configurable own property
  # cannot be deleted: the delete fails and returns false (sloppy mode; strict TypeError is P3). Otherwise the
  # property (and its attribute overlay entry) is removed and true is returned.
  defp odelete({:cell, id} = c, k) do
    ks = key_str(k)

    cond do
      has_own(c, ks) and not prop_configurable?(c, ks) ->
        false

      true ->
        {keys, map} = cell_read(c)
        Process.put(:gg_cells, Map.put(Process.get(:gg_cells, %{}), id, {List.delete(keys, ks), Map.delete(map, ks)}))
        pattr_del(c, ks)
        true
    end
  end
  # function objects: name/length are configurable — delete marks a tombstone (has_own goes false; reads fall
  # back to the Function.prototype defaults). Other fn props are removed from the per-function table.
  defp odelete({:fn, f} = fnv, k) do
    ks = key_str(k)

    if ks in ["name", "length"] do
      Process.put(:gg_fndel, Map.update(Process.get(:gg_fndel, %{}), f, MapSet.new([ks]), &MapSet.put(&1, ks)))
      true
    else
      {keys, map} = Process.get(:gg_fnprops, %{}) |> Map.get(f, {[], %{}})
      Process.put(:gg_fnprops, Map.put(Process.get(:gg_fnprops, %{}), f, {List.delete(keys, ks), Map.delete(map, ks)}))
      _ = fnv
      true
    end
  end

  defp odelete({:global, _}, k), do: key_str(k) != "prototype"
  defp odelete(_, _), do: true

  defp object_static("getPrototypeOf", _), do: :undefined
  defp object_static("setPrototypeOf", [o | _]), do: o
  # getOwnPropertyDescriptor(o, k): a data descriptor for an own property, else undefined. esbuild's
  # __copyProps reads `desc.enumerable`; we report own props as enumerable/writable/configurable.
  # function `.name`/`.length`: own, { writable:false, enumerable:false, configurable:true } per spec.
  defp object_static("getOwnPropertyDescriptor", [{:fn, _} = fnv, k | _]) do
    ks = to_str(k)
    cond do
      ks in ["name", "length"] ->
        cell_new([{"value", oget(fnv, ks)}, {"writable", false}, {"enumerable", false}, {"configurable", true}])

      has_own(fnv, ks) ->
        cell_new([{"value", oget(fnv, ks)}, {"writable", true}, {"enumerable", true}, {"configurable", true}])

      true ->
        :undefined
    end
  end

  defp object_static("getOwnPropertyDescriptor", [o, k | _]) do
    ks = to_str(k)

    if ks in Enum.map(own_keys_all(o), &to_str/1) do
      {w, e, c} = pattr_get(o, ks)

      case raw_prop(o, ks) do
        {:accessor, g, s} -> cell_new([{"get", g}, {"set", s}, {"enumerable", e}, {"configurable", c}])
        {:getter, g} -> cell_new([{"get", g}, {"set", :undefined}, {"enumerable", e}, {"configurable", c}])
        _ -> cell_new([{"value", oget(o, ks)}, {"writable", w}, {"enumerable", e}, {"configurable", c}])
      end
    else
      :undefined
    end
  end
  # getOwnPropertyDescriptors: { key => descriptor } for every own key — svelte's AST-node merge copies a
  # node's whole shape with this (`for (k in getOwnPropertyDescriptors(node)) defineProperty(clone, k, desc)`);
  # missing it silently dropped every field but the patched one, reducing FunctionDeclaration to just {id}.
  defp object_static("getOwnPropertyDescriptors", [o | _]) do
    cell_new(Enum.map(own_keys_all(o), fn k -> {to_str(k), object_static("getOwnPropertyDescriptor", [o, k])} end))
  end
  # Object.hasOwn(o, k) — svelte gates EVERY reactive read/assign transform on
  # `Object.hasOwn(state.transform, name) ? … : null`; returning undefined made the ternary pick null, so no
  # `$state`/`$props` use-site was ever rewritten (`count` stayed raw instead of `$.get(count)`).
  defp object_static("hasOwn", [o, k | _]), do: has_own(o, k)
  defp object_static("fromEntries", [o | _]) do
    pairs = for e <- okeys(o) |> Enum.map(&oget(o, &1)) || [], do: {to_str(oget(e, 0.0)), oget(e, 1.0)}
    cell_new(pairs)
  end
  defp object_static(_, _), do: :undefined

  defp array_static("isArray", [{:cell, id} | _]), do: Process.get({:gg_cellarr, id}) != nil
  defp array_static("isArray", [x | _]), do: match?({:arr, _}, x) or match?({:al, _}, x)
  defp array_static("from", [x | rest]) do
    # any iterable — Map yields [k,v] pairs, Set its members (rollup's getResolveStaticDependencyPromises is
    # Array.from(sourcesWithAttributes, async ([source, attributes]) => …) — a MAP with a mapper).
    items = iter(x)
    case rest do
      [{:fn, _} = f | _] -> avec(Enum.with_index(items) |> Enum.map(fn {v, i} -> call(f, [v, i * 1.0]) end))
      _ -> avec(items)
    end
  end
  defp array_static("of", args), do: avec(args)
  defp array_static(_, _), do: :undefined


  # floor/ceil/round/trunc/abs pass non-finite through (JS: Math.floor(NaN)=NaN, Math.round(Infinity)=Infinity) —
  # never crash on :nan/:infinity (GSAP's easing math feeds these through Math.round).
  defp math_static("floor", [x | _]), do: (n = to_number(x); if is_number(n), do: Float.floor(n / 1), else: n)
  defp math_static("ceil", [x | _]), do: (n = to_number(x); if is_number(n), do: Float.ceil(n / 1), else: n)
  # JS Math.round is half-toward-+Infinity (`round(-1.5) === -1`), i.e. floor(x + 0.5) — NOT Erlang's
  # round-half-away-from-zero.
  defp math_static("round", [x | _]), do: (n = to_number(x); if is_number(n), do: Float.floor(n + 0.5), else: n)
  defp math_static("trunc", [x | _]), do: (n = to_number(x); if is_number(n), do: trunc(n) * 1.0, else: n)
  defp math_static("abs", [x | _]), do: (n = to_number(x); cond do is_number(n) -> abs(n) * 1.0; n == :neg_infinity -> :infinity; true -> n end)
  defp math_static("sqrt", [x | _]), do: smath(&:math.sqrt/1, x)
  defp math_static("cbrt", [x | _]), do: (n = to_number(x); if n < 0, do: -:math.pow(-n, 1 / 3), else: :math.pow(n, 1 / 3))
  defp math_static("pow", [a, b | _]), do: js_pow(to_number(a), to_number(b))
  # trig / log / exp — all JS-safe (a domain error, e.g. log(-1)/acos(2)/sqrt(-1), is NaN in JS, not a crash).
  defp math_static("sin", [x | _]), do: smath(&:math.sin/1, x)
  defp math_static("cos", [x | _]), do: smath(&:math.cos/1, x)
  defp math_static("tan", [x | _]), do: smath(&:math.tan/1, x)
  defp math_static("asin", [x | _]), do: smath(&:math.asin/1, x)
  defp math_static("acos", [x | _]), do: smath(&:math.acos/1, x)
  defp math_static("atan", [x | _]), do: smath(&:math.atan/1, x)
  defp math_static("atan2", [y, x | _]), do: smath2(&:math.atan2/2, y, x)
  defp math_static("sinh", [x | _]), do: smath(&:math.sinh/1, x)
  defp math_static("cosh", [x | _]), do: smath(&:math.cosh/1, x)
  defp math_static("tanh", [x | _]), do: smath(&:math.tanh/1, x)
  defp math_static("exp", [x | _]), do: smath(&:math.exp/1, x)
  defp math_static("expm1", [x | _]), do: smath(fn n -> :math.exp(n) - 1 end, x)
  defp math_static("log", [x | _]), do: log_safe(&:math.log/1, x)
  defp math_static("log2", [x | _]), do: log_safe(&:math.log2/1, x)
  defp math_static("log10", [x | _]), do: log_safe(&:math.log10/1, x)
  defp math_static("log1p", [x | _]), do: smath(fn n -> :math.log(1 + n) end, x)
  defp math_static("hypot", args), do: smath(fn _ -> :math.sqrt(args |> Enum.map(&(to_number(&1) ** 2)) |> Enum.sum()) end, 0)

  # run a math fn, mapping an Erlang domain ArithmeticError to JS's NaN.
  defp smath(f, x) do
    n = to_number(x)
    if is_number(n), do: (try do f.(n) rescue ArithmeticError -> :nan end), else: :nan
  end

  defp smath2(f, a, b) do
    x = to_number(a)
    y = to_number(b)
    if is_number(x) and is_number(y), do: (try do f.(x, y) rescue ArithmeticError -> :nan end), else: :nan
  end

  # logarithms: log(0) is -Infinity, log(negative) is NaN (JS), not an Erlang crash.
  defp log_safe(f, x) do
    n = to_number(x)

    cond do
      not is_number(n) -> :nan
      n == 0 -> :neg_infinity
      n < 0 -> :nan
      true -> f.(n)
    end
  end
  defp math_static("max", args), do: (args |> Enum.filter(&is_number/1) |> Enum.max(fn -> 0.0 end)) * 1.0
  defp math_static("min", args), do: (args |> Enum.filter(&is_number/1) |> Enum.min(fn -> 0.0 end)) * 1.0
  defp math_static("random", _), do: :rand.uniform()
  defp math_static("sign", [x | _]), do: (cond do x > 0 -> 1.0; x < 0 -> -1.0; true -> 0.0 end)
  defp math_static(_, _), do: :undefined

  # calling a namespace/coercion function or a global function
  # coercion constructors — `Enum.at(args, 0, default)`, NOT `List.first(args) || default`: guest `false`
  # is Elixir `false`, so `List.first([false]) || :undefined` wrongly yields :undefined (String(false) was
  # "undefined", Number(false) was NaN). String() = "", Number() = 0, Boolean() = false with no args.
  # Proxy is not callable without `new` (spec: [[Call]] throws).
  def call({:global, "Proxy"}, _), do: type_error("Constructor Proxy requires 'new'")
  def call({:global, "String"}, []), do: ""
  def call({:global, "String"}, [a | _]), do: to_str(a)
  def call({:global, "Number"}, []), do: 0.0
  def call({:global, "Number"}, [a | _]), do: to_number(a)
  def call({:global, "Boolean"}, []), do: false
  def call({:global, "Boolean"}, [a | _]), do: truthy(a)
  def call({:global, "Array"}, [n]) when is_number(n), do: avec(List.duplicate(:undefined, trunc(n)))
  def call({:global, "Array"}, args), do: avec(args)
  def call({:global, "Object"}, [a | _]) when a != :undefined and a != :null, do: a
  def call({:global, "Object"}, _), do: olit()
  def call({:global, err}, args) when err in @error_names, do: construct({:global, err}, args)
  # Symbol(desc): a fresh unique symbol. Represented as {:symbol, id, desc}; identity is the id, so two
  # Symbol("x") differ. Usable as an object key (key_str tags it uniquely).
  def call({:global, "Symbol"}, args) do
    desc = case args do [d | _] when d != :undefined -> to_str(d); _ -> "" end
    {:symbol, __id(), desc}
  end
  def call({:global, _}, _args), do: :undefined

  def call({:globalfn, "parseInt"}, [x | _]), do: parse_int(x)
  def call({:globalfn, "parseFloat"}, [x | _]), do: parse_float(x)
  def call({:globalfn, "isNaN"}, [x | _]), do: to_number(x) == :nan
  def call({:globalfn, "isFinite"}, [x | _]), do: is_number(x)
  # BigInt(x) → arbitrary-precision `{:bigint, n}` (integer from a string, or the truncated number/bool).
  def call({:globalfn, "BigInt"}, [x | _]), do: {:bigint, bi_int(x)}
  def call({:globalfn, "BigInt"}, []), do: {:bigint, 0}
  def call({:globalfn, enc}, [x | _]) when enc in ["encodeURIComponent", "encodeURI"], do: URI.encode(to_str(x))
  def call({:globalfn, dec}, [x | _]) when dec in ["decodeURIComponent", "decodeURI"], do: URI.decode(to_str(x))
  # native MACROtask defer — node_shims' setTimeout(fn) lowers to __ggMacro(fn): enqueue the callback on the
  # macrotask queue (run by drain_microtasks' bounded event-loop turns), NOT the microtask queue. Returns a
  # timer id (0).
  def call({:globalfn, "__ggMacro"}, [f | _]) do
    if match?({:fn, _}, f) or match?({:host, _}, f), do: macro_enqueue(fn -> invoke(f, :undefined, []) end)
    0.0
  end

  def call({:globalfn, "__ggMacro"}, _), do: 0.0
  def call({:globalfn, _}, _), do: :undefined

  # top-level undefined/function/symbol → the VALUE undefined (String(JSON.stringify(undefined)) is "undefined");
  # nested, they become "null" (below).
  defp json_stringify(:undefined, _), do: :undefined
  defp json_stringify({:fn, _}, _), do: :undefined
  defp json_stringify({:host, _}, _), do: :undefined
  defp json_stringify({:symbol, _, _}, _), do: :undefined
  defp json_stringify(v, rest) do
    # the 3rd arg (`space`) selects pretty-printing: a number → that many spaces (max 10) per level; a string →
    # its first 10 chars as the indent unit; anything else → compact.
    case json_gap(Enum.at(rest, 1)) do
      "" -> json_enc(v)
      gap -> json_enc_p(v, gap, "")
    end
  end

  defp json_gap(n) when is_number(n), do: String.duplicate(" ", min(10, max(0, trunc(n))))
  defp json_gap(s) when is_binary(s), do: String.slice(s, 0, 10)
  defp json_gap(_), do: ""
  defp json_enc(n) when is_number(n), do: to_str(n)
  # NaN / ±Infinity are not valid JSON — serialize as null.
  defp json_enc(x) when x in [:nan, :infinity, :neg_infinity], do: "null"
  defp json_enc(true), do: "true"
  defp json_enc(false), do: "false"
  defp json_enc(:undefined), do: "null"
  defp json_enc(:null), do: "null"
  defp json_enc(s) when is_binary(s), do: json_quote(s)
  defp json_enc({t, _} = a) when t in [:arr, :al], do: "[" <> (al(a) |> Enum.map(&json_enc/1) |> Enum.join(",")) <> "]"
  defp json_enc({:fn, _}), do: "null"
  defp json_enc(o) do
    keys = okeys(o)
    body = keys |> Enum.map(fn k -> json_quote(k) <> ":" <> json_enc(oget(o, k)) end) |> Enum.join(",")
    "{" <> body <> "}"
  end

  # pretty (indented) encoder — mirrors json_enc but with newlines + `gap`-indentation for containers, and a
  # space after each object key's colon (matching JSON.stringify(v, null, space)). Primitives defer to json_enc.
  defp json_enc_p({t, _} = a, gap, ind) when t in [:arr, :al] do
    case al(a) do
      [] -> "[]"
      list ->
        ni = ind <> gap
        "[\n" <> (list |> Enum.map(fn v -> ni <> json_enc_p(v, gap, ni) end) |> Enum.join(",\n")) <> "\n" <> ind <> "]"
    end
  end

  defp json_enc_p(v, _gap, _ind)
       when is_number(v) or is_binary(v) or is_boolean(v) or v in [:null, :undefined, :nan, :infinity, :neg_infinity],
       do: json_enc(v)

  defp json_enc_p({:fn, _}, _gap, _ind), do: "null"

  defp json_enc_p(o, gap, ind) do
    case okeys(o) do
      [] -> "{}"
      keys ->
        ni = ind <> gap
        body = keys |> Enum.map(fn k -> ni <> json_quote(k) <> ": " <> json_enc_p(oget(o, k), gap, ni) end) |> Enum.join(",\n")
        "{\n" <> body <> "\n" <> ind <> "}"
    end
  end

  defp json_quote(s), do: "\"" <> (s |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"") |> String.replace("\n", "\\n")) <> "\""

  defp json_parse(s) do
    try do
      TinyLasers.Wasm.Json.decode!(s) |> json_to_guest()
    rescue
      _ -> :undefined
    end
  end

  defp json_to_guest(n) when is_number(n), do: n / 1
  defp json_to_guest(b) when is_boolean(b), do: b
  defp json_to_guest(nil), do: :null
  defp json_to_guest(s) when is_binary(s), do: s
  defp json_to_guest(l) when is_list(l), do: avec(Enum.map(l, &json_to_guest/1))
  defp json_to_guest(m) when is_map(m), do: Enum.reduce(m, olit(), fn {k, v}, acc -> oput(acc, to_string(k), json_to_guest(v)) end)

  # parseInt/parseFloat coerce to STRING first (NOT ToNumber): parseInt(true) is parseInt("true") = NaN, not 1.
  defp parse_int(x) do
    case Integer.parse(String.trim(to_str(x))) do
      {n, _} -> n * 1.0
      :error -> :nan
    end
  end

  defp parse_float(x) do
    t = String.trim(to_str(x))

    cond do
      String.starts_with?(t, "Infinity") or String.starts_with?(t, "+Infinity") -> :infinity
      String.starts_with?(t, "-Infinity") -> :neg_infinity
      true ->
        case Float.parse(t) do
          {n, _} -> n
          :error -> (case Integer.parse(t) do {n, _} -> n * 1.0; :error -> :nan end)
        end
    end
  end

  @doc "ToNumber coercion (public: unary + uses it)."
  def to_number(x) when is_number(x), do: x
  def to_number({:bigint, n}), do: n * 1.0
  def to_number({:date, ms}), do: ms
  def to_number(x) when x in [:infinity, :neg_infinity, :nan], do: x
  def to_number(true), do: 1.0
  def to_number(false), do: 0.0
  def to_number(:null), do: 0.0
  def to_number(:undefined), do: :nan
  def to_number(s) when is_binary(s) do
    t = String.trim(s)

    cond do
      t == "" -> 0.0
      # JS accepts 0x/0o/0b integer literals as numbers.
      String.match?(t, ~r/^0[xX][0-9a-fA-F]+$/) -> String.to_integer(String.slice(t, 2..-1//1), 16) * 1.0
      String.match?(t, ~r/^0[oO][0-7]+$/) -> String.to_integer(String.slice(t, 2..-1//1), 8) * 1.0
      String.match?(t, ~r/^0[bB][01]+$/) -> String.to_integer(String.slice(t, 2..-1//1), 2) * 1.0
      true ->
        case Float.parse(t) do
          {n, ""} -> n
          _ -> case Integer.parse(t) do {n, ""} -> n * 1.0; _ -> :nan end
        end
    end
  end
  # array/object coercion: ToPrimitive → string → number (`Number([]) === 0`, `Number([1]) === 1`,
  # `Number([1,2])` is NaN, `Number({})` is NaN).
  def to_number({t, _} = a) when t in [:arr, :al], do: to_number(to_str(a))
  def to_number({:cell, _} = o), do: to_number(to_primitive(o))
  def to_number(_), do: :nan

  # Function.prototype.apply/call/bind (marked + minified helpers use these heavily).
  def method({:fn, _} = f, "apply", args) do
    this = List.first(args) || :undefined
    argl = case args do [_, {:arr, _} = av | _] -> al(av); _ -> [] end
    invoke(f, this, argl)
  end

  def method({:protom, :tostring}, m, [x | _]) when m in ["call", "apply"], do: to_string_tag(x)
  def method({:protom, :tostring}, m, []) when m in ["call", "apply"], do: to_string_tag(:undefined)
  def method({:protom, :hasown}, "call", [o, k | _]), do: has_own(o, k)
  def method({:protom, :hasown}, "apply", [o, {:arr, _} = av | _]), do: has_own(o, List.first(al(av)))
  # constructor objects: RegExp.hasOwnProperty('prototype') etc. (S15.10.5.1). 'prototype' is own,
  # non-enumerable, non-deletable; the statics list covers the callable own props.
  def method({:global, g}, "hasOwnProperty", [k | _]) when is_binary(g),
    do: key_str(k) == "prototype" or key_str(k) in @global_static_methods
  def method({:global, _}, "propertyIsEnumerable", [_ | _]), do: false
  # prototype objects: RegExp.prototype.isPrototypeOf(re) — match the value's tag to the prototype's name.
  def method({:proto, name}, "isPrototypeOf", [v | _]), do: proto_of_tag(v) == name
  def method({:proto, _}, "hasOwnProperty", [k | _]), do: key_str(k) == "constructor"

  def method({:protom, :propisenum}, "call", [o, k | _]), do: prop_is_enum(o, k)
  def method({:protom, :propisenum}, "apply", [o, {:arr, _} = av | _]), do: prop_is_enum(o, List.first(al(av)))
  def method({:fn, _} = f, "call", [this | rest]), do: invoke(f, this, rest)
  def method({:fn, _} = f, "call", []), do: invoke(f, :undefined, [])
  # a function's source is NOT retained through lowering — `fn.toString()` returns a canonical placeholder.
  # (Libraries that embed serialized function SOURCE, e.g. seroval for SSR hydration, get a stand-in; this is a
  # fundamental limit of compile-to-BEAM. With hydratable:false the placeholder never reaches the output.)
  def method({:fn, _}, "toString", _), do: "function () { }"
  def method({:host, _}, "toString", _), do: "function () { [native code] }"

  def method({:fn, _} = f, "bind", [this | bound]) do
    closure(fn _ignored_this, args -> invoke(f, this, bound ++ args) end)
  end
  # `.bind()` with no args: bind `this` to undefined (marked: `Object.assign.bind()`).
  def method({:fn, _} = f, "bind", []), do: closure(fn _ignored_this, args -> invoke(f, :undefined, args) end)

  # a property call on a function object: `marked.parse(md)` — look up the function-valued property + invoke.
  def method({:fn, fref} = fnv, name, args) do
    case oget(fnv, name) do
      {:fn, _} = g -> invoke(g, fnv, args)
      other ->
        if System.get_env("GAPLOG") do
          keys = Process.get(:gg_fnprops, %{}) |> Map.get(fref, {[], %{}}) |> elem(0) |> Enum.take(8)
          IO.puts(:stderr, "GAP fnmeth #{inspect(name)} -> #{inspect(other)|>String.slice(0,30)} fnkeys=#{inspect(keys)}")
        end
        guest_error("not a function")
    end
  end

  # a method call on null/undefined fails at the PROPERTY read (spec: `Cannot read properties of …`).
  def method(:undefined, nm, _a) do
    if System.get_env("GAPSOFT"), do: :undefined, else: type_error("Cannot read properties of undefined (reading '#{key_str(nm)}')")
  end
  def method(:null, nm, _a), do: type_error("Cannot read properties of null (reading '#{key_str(nm)}')")

  # calling a method that doesn't resolve is a guest TypeError, NOT a host escape — the receiver was never a
  # host reference. Throw a real TypeError OBJECT so a guest catch sees `e instanceof TypeError`.
  def method(r, nm, _a) do
    if System.get_env("GAPLOG") do
      extra = if System.get_env("GAPTRACE") do
        Process.info(self(), :current_stacktrace) |> elem(1)
        |> Enum.filter(fn {m,_,_,_} -> m |> to_string() =~ ~r/Runtime|Guest/ end) |> Enum.take(6)
        |> Enum.map_join(" <- ", fn {_,f,a,_} -> "#{f}/#{a}" end)
      else "" end
      IO.puts(:stderr, "GAP method #{inspect(nm)} on #{inspect(r) |> String.slice(0, 40)} #{extra}")
    end
    if System.get_env("GAPSOFT"), do: :undefined, else: type_error("#{key_str(nm)} is not a function")
  end


  defp slice_list(list, a, rest) do
    n = length(list)
    start = trunc(num(a))
    start = if start < 0, do: max(n + start, 0), else: min(start, n)
    stop = case rest do
      [b | _] when b != :undefined -> e = trunc(num(b)); if e < 0, do: max(n + e, 0), else: min(e, n)
      _ -> n
    end
    Enum.slice(list, start, max(stop - start, 0))
  end

  # code-point count (JS string length) with an all-ASCII fast path. JS strings can hold ARBITRARY code units
  # (e.g. linkedom packs binary entity/decode tables into strings via fromCharCode), which are not valid UTF-8 —
  # `String.to_charlist` raises on those, so fall back to the byte count instead of crashing the runtime.
  defp str_len(s) do
    cond do
      ascii?(s) -> byte_size(s)
      true -> length(safe_charlist(s))
    end
  end

  # code points for indexing/slicing. For strings holding arbitrary code units (linkedom's packed binary
  # entity/decode tables) that aren't valid UTF-8, treat each byte as a code unit (JS "code unit 0–255"
  # semantics) rather than raising.
  defp safe_charlist(s) do
    case :unicode.characters_to_list(s) do
      l when is_list(l) -> l
      _ -> :binary.bin_to_list(s)
    end
  end
  # all-ASCII check (the common case → the byte ops are already correct): no byte has the high bit set.
  defp ascii?(<<>>), do: true
  defp ascii?(<<b, rest::binary>>) when b < 128, do: ascii?(rest)
  defp ascii?(_), do: false

  # slice/substring on CODE POINTS (JS semantics), ASCII fast path via binary_part.
  defp str_slice(s, a, rest) do
    n = str_len(s)
    start = trunc(num(a))
    start = if start < 0, do: max(n + start, 0), else: min(start, n)
    stop = case rest do
      [b | _] when b != :undefined -> e = trunc(num(b)); if e < 0, do: max(n + e, 0), else: min(e, n)
      _ -> n
    end
    cp_sub(s, start, max(stop - start, 0))
  end

  # substring(a,b): clamps to [0,len], swaps if a>b (JS semantics), no negatives.
  defp str_substring(s, a, rest) do
    len = str_len(s)
    a = a |> trunc() |> max(0) |> min(len)
    b = case rest do [x | _] when is_number(x) -> x |> trunc() |> max(0) |> min(len); _ -> len end
    lo = min(a, b)
    cp_sub(s, lo, max(a, b) - lo)
  end

  defp cp_sub(s, start, len) do
    if ascii?(s), do: binary_part(s, start, len), else: (safe_charlist(s) |> Enum.slice(start, len) |> List.to_string())
  end

  defp str_pad(s, len, rest, side) do
    target = trunc(len)
    pad = case rest do [p | _] -> to_str(p); _ -> " " end
    # target length is in CODE UNITS, not bytes — `"café".padStart(8, "*")` adds 4 stars (len 4), not 3.
    slen = str_len(s)

    if slen >= target or pad == "" do
      s
    else
      need = target - slen
      plen = max(str_len(pad), 1)
      fill = String.duplicate(pad, div(need, plen) + 1) |> String.slice(0, need)
      if side == :leading, do: fill <> s, else: s <> fill
    end
  end

  defp num(v) when is_number(v), do: v
  defp num(_), do: 0

  @doc "A guest function as a DIRECTLY-HELD closure (GC'd, no table). The fun takes `(this, args)`; safe —
  the guest can only invoke it via `call/2` or `invoke/3`, and no codegen path extracts and `apply`s it."
  def closure(f) when is_function(f, 2), do: {:fn, f}

  # ── function name/length metadata (spec own, non-enumerable, non-writable, configurable properties) ──
  # A fresh fn value records its `.length` (arity = params before the first default/rest) here; the name starts
  # "" and is filled by set_fn_name at a named declaration/expression or a NamedEvaluation assignment target.
  # Keyed by the closure `f` (same pattern as :gg_fnprops). Lower/Walk wrap every function value with fn_meta/2.
  def fn_meta({:fn, f} = v, len) do
    m = Process.get(:gg_fnmeta, %{})
    name = case Map.get(m, f) do {n, _} -> n; _ -> "" end
    Process.put(:gg_fnmeta, Map.put(m, f, {name, len}))
    v
  end
  def fn_meta(v, _len), do: v

  @doc "Assign an inferred name to a still-anonymous function (NamedEvaluation: `const f = () => {}` ⇒ 'f')."
  def set_fn_name({:fn, f} = v, name) do
    m = Process.get(:gg_fnmeta, %{})
    case Map.get(m, f, {"", 0}) do
      {"", len} -> Process.put(:gg_fnmeta, Map.put(m, f, {to_string(name), len})); v
      _ -> v
    end
  end
  def set_fn_name(v, _name), do: v

  defp fn_deleted?(f, k), do: Process.get(:gg_fndel, %{}) |> Map.get(f, MapSet.new()) |> MapSet.member?(k)
  defp fn_name_meta(f), do: (case Process.get(:gg_fnmeta, %{}) |> Map.get(f) do {n, _} -> n; _ -> "" end)
  defp fn_len_meta(f), do: (case Process.get(:gg_fnmeta, %{}) |> Map.get(f) do {_, l} -> l; _ -> 0 end)

  defp instanceof_chain(nil, _target), do: false
  defp instanceof_chain(proto, target) do
    proto == target or instanceof_chain((case proto do {:cell, pid} -> Process.get({:gg_instproto, pid}); _ -> nil end), target)
  end

  # is `v` a non-primitive (an object, for `instanceof Object` / `typeof … === "object"` purposes)? Primitives:
  # number, string, boolean, null/undefined, NaN/±Infinity, symbol, bigint. Everything else is object-like.
  defp object_like?(v) do
    not (is_number(v) or is_binary(v) or is_boolean(v) or is_nil(v) or
           v in [:null, :undefined, :nan, :infinity, :neg_infinity] or
           match?({:symbol, _, _}, v) or match?({:bigint, _}, v))
  end

  # ── Promise internals (synchronous/eager; see the method clauses above) ──
  # ── microtask queue: settle/then NEVER run callbacks inline (that recursed settle→then→settle unboundedly,
  # growing the BEAM stack until OOM). Instead callbacks are ENQUEUED and a drain loop runs them iteratively
  # (bounded, constant stack). This also gives correct JS microtask ordering. ──
  defp mq_enqueue(thunk), do: Process.put(:gg_microq, :queue.in(thunk, Process.get(:gg_microq, :queue.new())))

  defp mq_take do
    case :queue.out(Process.get(:gg_microq, :queue.new())) do
      {{:value, thunk}, q2} -> Process.put(:gg_microq, q2); thunk
      {:empty, _} -> nil
    end
  end

  @doc """
  True while an ASYNC CONTINUATION is executing — a microtask (`.then`/`await` resumption) or a macrotask
  (`setTimeout`) callback dispatched by the event-loop drain, as opposed to code on the guest's direct
  synchronous call stack. The TDZ guard uses this to disambiguate a cross-function-boundary read of a
  not-yet-initialized let/const: at depth 0 the closure was invoked SYNCHRONOUSLY (an IIFE run during the
  initializer) — a real temporal-dead-zone error that throws; at depth >0 the closure was invoked by the async
  machinery AFTER the sync frame that initializes the binding (rollup's `.then(() => outerConst)`), a legit
  late read that degrades to :undefined. In the eager promise model these two only differ by drain depth.
  """
  def in_async_continuation?, do: Process.get(:gg_mt_depth, 0) > 0

  # run one queued continuation thunk with the async-continuation depth bumped for its dynamic extent.
  defp run_cont(thunk) do
    d = Process.get(:gg_mt_depth, 0)
    Process.put(:gg_mt_depth, d + 1)
    try do
      thunk.()
    after
      Process.put(:gg_mt_depth, d)
    end
  end

  # Runaway-promise-loop detector for the MICROtask queue (real Promise.then chains). Genuine async is bounded
  # in the thousands; a truly unbounded microtask reschedule is a bug, caught as a catchable guest_error.
  @microtask_cap 5_000_000

  # MACROtasks (setTimeout/setImmediate) are a SEPARATE queue, drained for a bounded number of "event-loop turns"
  # (each turn: run the macrotasks queued so far, then flush microtasks; macrotasks scheduled DURING a turn go to
  # the next turn — real event-loop semantics). This is why setTimeout no longer reschedules inside the microtask
  # drain: e.g. GSAP's ticker reschedules a setTimeout every tick FOREVER; with a fake-macrotask (Promise.then)
  # that spun the microtask drain to millions of iterations (~2.9GB of {:gg_prom}/{:gg_box}). As a real macrotask
  # it runs at most @macro_turns ticks. One turn suffices for the common finite case (Solid's setTimeout(dispose)
  # must run after the sync render). See f2-object-store-leak.
  @macro_turns 16

  defp macro_enqueue(thunk), do: Process.put(:gg_macroq, :queue.in(thunk, Process.get(:gg_macroq, :queue.new())))

  defp macro_take_all do
    q = Process.get(:gg_macroq, :queue.new())
    Process.put(:gg_macroq, :queue.new())
    :queue.to_list(q)
  end

  @doc "Run the event loop after the top-level guest code: flush microtasks, then bounded macrotask turns."
  def drain_microtasks(n \\ 0)

  def drain_microtasks(_n) do
    drain_micro(0)
    run_macro_turns(0)
    :ok
  end

  defp drain_micro(n) when n >= @microtask_cap, do: guest_error("microtask overflow — unresolved promise loop")

  defp drain_micro(n) do
    case mq_take() do
      nil -> :ok
      thunk -> run_cont(thunk); drain_micro(n + 1)
    end
  end

  defp run_macro_turns(t) when t >= @macro_turns, do: :ok

  defp run_macro_turns(t) do
    case macro_take_all() do
      [] ->
        :ok

      macros ->
        Enum.each(macros, fn thunk ->
          (try do run_cont(thunk) catch :throw, _ -> :ok end)
          drain_micro(0)
        end)

        run_macro_turns(t + 1)
    end
  end

  defp new_promise do
    id = __id()
    Process.put({:gg_prom, id}, {:pending, :undefined, []})
    {:promise, id}
  end

  defp prom_state({:promise, id}), do: Process.get({:gg_prom, id}, {:pending, :undefined, []})

  # settle a pending promise. Resolving with a thenable adopts its eventual state (via prom_on — a SIDE-EFFECT
  # subscription whose return value is ignored, unlike prom_then). Otherwise record state + enqueue callbacks.
  defp settle({:promise, id} = p, kind, value) do
    case prom_state(p) do
      {:pending, _, cbs} ->
        if kind == :fulfilled and match?({:promise, _}, value) do
          prom_on(value, fn v -> settle(p, :fulfilled, v) end, fn e -> settle(p, :rejected, e) end)
          :ok
        else
          Process.put({:gg_prom, id}, {kind, value, []})
          Enum.each(:lists.reverse(cbs), fn cb -> mq_enqueue(fn -> cb.(kind, value) end) end)
        end

      _ -> :ok
    end
    p
  end

  # subscribe an INTERNAL side-effect to a promise (Promise.all accumulation, thenable adoption). The handler
  # is a plain 1-arg Elixir fun; its return value is IGNORED — no out-promise, no return-adoption. (prom_then,
  # by contrast, settles an out-promise with the handler's return — for that, an internal handler returning a
  # promise would be re-adopted every cycle → infinite microtask loop.)
  defp prom_on(p, on_f, on_r) do
    cb = fn kind, value -> (if kind == :fulfilled, do: on_f, else: on_r).(value) end
    case prom_state(p) do
      {:pending, _, cbs} -> Process.put(elem_key(p), {:pending, :undefined, [cb | cbs]})
      {kind, value, _} -> mq_enqueue(fn -> cb.(kind, value) end)
    end
    :ok
  end

  # .then: returns a new promise; the handler runs as a MICROTASK (enqueued), never inline.
  defp prom_then(p, on_f, on_r) do
    out = new_promise()
    cb = fn kind, value ->
      handler = if kind == :fulfilled, do: on_f, else: on_r
      if match?({:fn, _}, handler) or match?({:host, _}, handler) do
        try do
          settle(out, :fulfilled, invoke(handler, :undefined, [value]))
        catch
          :throw, {:gg_guest_error, e} -> settle(out, :rejected, e)
          :throw, {:gg_throw, e} -> settle(out, :rejected, e)
        end
      else
        # no handler: pass the settled value/reason straight through
        settle(out, kind, value)
      end
    end
    case prom_state(p) do
      {:pending, _, cbs} -> Process.put(elem_key(p), {:pending, :undefined, [cb | cbs]})
      {kind, value, _} -> mq_enqueue(fn -> cb.(kind, value) end)
    end
    out
  end

  defp elem_key({:promise, id}), do: {:gg_prom, id}
  defp invoke_if(f, args), do: (if match?({:fn, _}, f) or match?({:host, _}, f), do: invoke(f, :undefined, args), else: :undefined)

  @doc "Run an async function body thunk, producing a promise: resolves with its (awaited) result, or rejects
  on a thrown guest error / rejected await."
  def promise_from(thunk) do
    try do
      settle(new_promise(), :fulfilled, thunk.())
    catch
      :throw, {:gg_guest_error, e} -> settle(new_promise(), :rejected, e)
      :throw, {:gg_throw, e} -> settle(new_promise(), :rejected, e)
    end
  end

  @doc "`await x`: drain microtasks until the awaited promise settles, then unwrap (rejected → re-throw)."
  def await_({:promise, _} = p), do: (drain_until(p, 0); await_read(p))
  def await_(v), do: v

  defp await_read(p) do
    case prom_state(p) do
      {:fulfilled, v, _} -> v
      {:rejected, e, _} -> throw_val(e)
      # the eager model has no timers/IO: a promise still pending after a full drain means a resolve was LOST
      # (a real bug — silently yielding undefined here hid a dead module-graph build for days). Fail loudly.
      {:pending, _, _} -> guest_error("await on a never-settling promise (lost resolve — eager model has no timers)")
    end
  end

  # run microtasks until `p` leaves pending (or the queue empties / cap hit).
  defp drain_until(p, n) do
    case prom_state(p) do
      {:pending, _, _} when n < @microtask_cap ->
        case mq_take() do
          nil -> :ok
          thunk -> run_cont(thunk); drain_until(p, n + 1)
        end
      _ -> :ok
    end
  end

  defp promise_static("resolve", [v | _]), do: (if match?({:promise, _}, v), do: v, else: settle(new_promise(), :fulfilled, v))
  defp promise_static("resolve", []), do: settle(new_promise(), :fulfilled, :undefined)
  defp promise_static("reject", [e | _]), do: settle(new_promise(), :rejected, e)
  defp promise_static("reject", []), do: settle(new_promise(), :rejected, :undefined)
  # Promise.all: settle `out` with the results array once every input fulfils (reject on first rejection).
  # Correct async: register a then on each input; accumulate results in an out-keyed process slot.
  defp promise_static("all", [{:arr, _} = av | _]) do
    items = al(av)
    out = new_promise()
    total = length(items)
    if total == 0 do
      settle(out, :fulfilled, avec([]))
    else
      Process.put({:gg_all, elem(out, 1)}, {total, List.duplicate(:undefined, total)})
      items |> Enum.with_index() |> Enum.each(fn {item, i} ->
        prom_on(promise_wrap(item), fn v -> all_collect(out, i, v) end, fn e -> settle(out, :rejected, e) end)
      end)
      out
    end
  end
  defp promise_static("allSettled", [{:arr, _} = av | _]) do
    items = al(av)
    out = new_promise()
    total = length(items)
    if total == 0 do
      settle(out, :fulfilled, avec([]))
    else
      Process.put({:gg_all, elem(out, 1)}, {total, List.duplicate(:undefined, total)})
      items |> Enum.with_index() |> Enum.each(fn {item, i} ->
        prom_on(promise_wrap(item),
          fn v -> all_collect(out, i, cell_new([{"status", "fulfilled"}, {"value", v}])) end,
          fn e -> all_collect(out, i, cell_new([{"status", "rejected"}, {"reason", e}])) end)
      end)
      out
    end
  end
  defp promise_static("race", [{:arr, _} = av | _]) do
    out = new_promise()
    Enum.each(al(av), fn item ->
      prom_on(promise_wrap(item), fn v -> settle(out, :fulfilled, v) end, fn e -> settle(out, :rejected, e) end)
    end)
    out
  end
  defp promise_static(_, _), do: :undefined

  # record result i for a Promise.all/allSettled `out`; settle when all have arrived.
  defp all_collect(out, i, v) do
    {rem, results} = Process.get({:gg_all, elem(out, 1)})
    results = List.replace_at(results, i, v)
    if rem - 1 == 0 do
      settle(out, :fulfilled, avec(results))
    else
      Process.put({:gg_all, elem(out, 1)}, {rem - 1, results})
    end
  end

  defp promise_wrap({:promise, _} = p), do: p
  defp promise_wrap(v), do: settle(new_promise(), :fulfilled, v)

  @doc "Link a child constructor's prototype to its parent's (ES6 `class Child extends Parent`), so inherited
  instance methods resolve by walking child.prototype -> parent.prototype. Also records the ctor-level super
  link for static inheritance."
  def set_proto_chain({:fn, _} = child, {:fn, _} = parent) do
    {:cell, cid} = fn_proto(child)
    Process.put({:gg_instproto, cid}, fn_proto(parent))
    Process.put({:gg_superctor, child_key(child)}, parent)
    :undefined
  end
  def set_proto_chain(_, _), do: :undefined

  defp child_key({:fn, f}), do: f

  # a function's prototype cell (stable per closure) — the ES5 method bag for `new Ctor()` instances.
  defp fn_proto({:fn, f}) do
    case Process.get(:gg_fnproto, %{}) |> Map.get(f) do
      nil ->
        pc = cell_new([])
        Process.put(:gg_fnproto, Map.put(Process.get(:gg_fnproto, %{}), f, pc))
        pc

      pc ->
        pc
    end
  end

  # top-level function registry: late binding so forward references + mutual recursion work (fn A calls fn B
  # declared after it). Functions are few and per-run, so a small process-dict table is fine (the GC concern
  # was OBJECTS, not functions). A guest can only reach these by NAME resolved at compile time to greg_get.
  @doc "Register a top-level guest function by name."
  # returns the stored value (not Process.put's OLD value) so `x = (f = impl)` and assignment-as-expression
  # evaluate to the RHS.
  def greg_set(name, closure), do: (Process.put({:gg_fn, name}, closure); closure)

  @doc """
  Chunk-function dispatch for the exploded/parallel compile: sibling guest modules register their chunk
  functions as plain funs (`cf_reg`) and callers invoke by NAME (`cf`) — so no guest binary ever holds a
  reference to another module, keeping per-module confinement checks self-contained.
  """
  def cf_reg(name, fun) when is_function(fun, 1), do: Process.put({:gg_cf, name}, fun)
  def cf(name, env), do: Process.get({:gg_cf, name}).(env)
  @doc "Resolve a top-level guest function by name (late) — `:undefined` if never declared."
  def greg_get(name), do: Process.get({:gg_fn, name}, :undefined)

  @doc "`new F(args)` — construct an instance: fresh `this` cell, invoke the constructor, return the instance
  (the constructor's returned object if it returns one, else the mutated `this`). Error constructors make an
  error object; `new RegExp` is handled at the codegen level."
  def construct({:fn, _} = f, args) do
    this = cell_new([])
    {:cell, iid} = this
    # link the instance to its constructor's prototype so method lookups resolve ES5 class methods.
    Process.put({:gg_instproto, iid}, fn_proto(f))

    case invoke(f, this, args) do
      {tag, _} = obj when tag in [:cell, :arr] -> obj
      {keys, map} = obj when is_map(map) -> obj
      _ -> this
    end
  end

  def construct({:global, err}, args) when err in @error_names,
    do: mk_error(err, to_str(List.first(args) || ""))

  # an error object carries its `.constructor` (the global error fn) so `thrown.constructor === TypeError`
  # holds (test262's assert.throws checks constructor IDENTITY, not just `.name`), and its prototype is linked
  # to `{:proto, err}` so `e instanceof TypeError` / `e instanceof Error` and `e.toString()` work.
  defp mk_error(err, msg) do
    {:cell, id} = c = cell_new([{"message", msg}, {"name", err}, {"constructor", {:global, err}}])
    Process.put({:gg_instproto, id}, {:proto, err})
    c
  end

  # `new Array(n)` with a single numeric arg is a length-n hole array (rollup: `new Array(list.length)`),
  # NOT a one-element array containing n.
  def construct({:global, "Array"}, [n]) when is_number(n), do: avec(List.duplicate(:undefined, trunc(n)))
  def construct({:global, "Array"}, args), do: avec(args)
  # Proxy: {:proxy, target, handler}. Property get/set + method calls route through the handler's traps
  # (falling back to the target). rollup's output bundle is a Proxy over the chunk map.
  def construct({:global, "Proxy"}, [target, handler | _]) do
    unless object_like?(target), do: type_error("Cannot create proxy with a non-object as target")
    unless object_like?(handler), do: type_error("Cannot create proxy with a non-object as handler")
    {:proxy, target, handler}
  end
  def construct({:global, "Proxy"}, _short), do: type_error("Cannot create proxy with a non-object as target or handler")
  # Date — a deterministic stub (epoch 0). rollup uses it only for timing (Number(new Date())), not output,
  # so a fixed value keeps the bundle byte-identical.
  def construct({:global, "Date"}, args), do: {:date, (case args do [n | _] when is_number(n) -> n; _ -> 0.0 end)}
  # TextDecoder/TextEncoder — guest strings are UTF-8 binaries, so decode/encode are near-identity.
  def construct({:global, "TextDecoder"}, _), do: {:textdecoder}
  def construct({:global, "TextEncoder"}, _), do: {:textencoder}
  # Real ArrayBuffer-backed typed arrays: `{:ta, kind, abuf_id, byte_off, len}` views over an `{:abuf, id, blen}`
  # linear byte buffer. This gives `.buffer` + reinterpretation — rollup reads its AST as
  # `new Uint32Array(uint8.buffer)`, which needs the u8 bytes viewable as u32s.
  def construct({:global, "ArrayBuffer"}, [n | _]) when is_number(n), do: mk_abuf(:binary.copy(<<0>>, trunc(n)))
  # DataView over an ArrayBuffer — typed reads/writes at a byte offset (rollup reads AST numeric literals via
  # new DataView(buffer.buffer).getFloat64(byteOffset, true)).
  def construct({:global, "DataView"}, [{:abuf, id, blen} | rest]) do
    off = trunc(to_number(Enum.at(rest, 0) || 0.0))
    len = case Enum.at(rest, 1) do nil -> blen - off; l -> trunc(to_number(l)) end
    {:dataview, id, off, len}
  end
  def construct({:global, ta}, args)
      when ta in ["Uint8Array", "Int8Array", "Uint16Array", "Int16Array", "Uint32Array",
                  "Int32Array", "Float32Array", "Float64Array"] do
    kind = ta_kind(ta)
    sz = ta_size(kind)
    case args do
      # new TA(arrayBuffer[, byteOffset[, length]]) — a VIEW sharing the buffer.
      [{:abuf, id, blen} | rest] ->
        off = trunc(to_number(Enum.at(rest, 0) || 0.0))
        len = case Enum.at(rest, 1) do nil -> div(blen - off, sz); l -> trunc(to_number(l)) end
        {:ta, kind, id, off, len}
      # new TA(otherTypedArray) / new TA([...]) — copy elements into a fresh buffer.
      [{:ta, _, _, _, _} = src | _] -> ta_from_elems(kind, ta_elems(src))
      [{:arr, _} = av | _] -> ta_from_elems(kind, al(av))
      [{:bytes, b} | _] -> ta_from_elems(kind, :binary.bin_to_list(b) |> Enum.map(&(&1 * 1.0)))
      [n | _] when is_number(n) -> {:abuf, id, _} = mk_abuf(:binary.copy(<<0>>, trunc(n) * sz)); {:ta, kind, id, 0, trunc(n)}
      _ -> {:abuf, id, _} = mk_abuf(""); {:ta, kind, id, 0, 0}
    end
  end
  def construct({:global, "Object"}, _), do: cell_new([])
  # `new Set(iterable)` — ANY iterable (rollup does `new Set(this.includedImports)`, a Set-from-Set copy;
  # accepting only arrays silently produced an empty set and dropped every cross-module chunk dependency).
  def construct({:global, s}, args) when s in ["Set", "WeakSet"] do
    id = __id()
    init = case args do [x | _] -> Enum.uniq(iter(x)); _ -> [] end
    Process.put({:gg_set, id}, init)
    {:set, id}
  end

  # new Promise(executor): run the executor synchronously with (resolve, reject); a synchronous resolve/reject
  # settles now (eager model). A throwing executor rejects.
  def construct({:global, "Promise"}, [executor | _]) do
    p = new_promise()
    res = closure(fn _t, a -> settle(p, :fulfilled, List.first(a) || :undefined) end)
    rej = closure(fn _t, a -> settle(p, :rejected, List.first(a) || :undefined) end)
    try do
      invoke(executor, :undefined, [res, rej])
    catch
      :throw, {:gg_guest_error, e} -> settle(p, :rejected, e)
      :throw, {:gg_throw, e} -> settle(p, :rejected, e)
    end
    p
  end

  # `new Map(iterable-of-pairs)` — any iterable of [k, v] entries (including another Map, whose iteration
  # yields [k, v] arrays).
  def construct({:global, m}, args) when m in ["Map", "WeakMap"] do
    id = __id()

    init =
      case args do
        [x | _] ->
          Enum.map(iter(x), fn e ->
            case (if match?({:arr, _}, e), do: al(e), else: []) do
              [k, v | _] -> {k, v}
              _ -> {:undefined, :undefined}
            end
          end)

        _ ->
          []
      end

    Process.put({:gg_map, id}, init)
    {:map, id}
  end

  def construct(nc, args) do
    if System.get_env("GAPLOG") do
      st = if System.get_env("GAPTRACE") do
        Process.info(self(), :current_stacktrace) |> elem(1) |> Enum.filter(fn {m,_,_,_} -> m |> to_string() =~ ~r/Guest|Runtime/ end) |> Enum.take(6) |> Enum.map_join(" <- ", fn {_,f,a,_} -> "#{f}/#{a}" end)
      else "" end
      akeys = args |> Enum.map(fn a -> if match?({:cell,_}, a), do: okeys(a) |> Enum.take(6), else: a end) |> inspect() |> String.slice(0, 100)
      IO.puts(:stderr, "GAP construct #{inspect(nc)|>String.slice(0,50)} @#{inspect(Process.get(:gg_pos))} argkeys=#{akeys} #{st}")
    end
    if System.get_env("GAPSOFT"), do: cell_new([]), else: guest_error("not a constructor")
  end

  @doc "Invoke a guest function with an explicit `this` receiver (method call). Ungranted callees error."
  def invoke({:fn, f}, this, args) when is_function(f, 2), do: f.(this, args)
  def invoke({:host, cap_id}, _this, args), do: host_call(cap_id, args)
  # `super()` to a built-in — `class X extends Set/Map` etc. Back the instance cell with a real collection
  # (so this.add/.has/.size delegate); other built-ins merge their constructed cell's keys into `this`.
  def invoke({:global, coll}, {:cell, id} = this, args) when coll in ["Set", "WeakSet", "Map", "WeakMap"] do
    Process.put({:gg_cellcoll, id}, construct({:global, coll}, args))
    this
  end
  # `super()` in a `class X extends Array` — back the instance cell with a real array so this.push/.length/
  # indexed access delegate. `new X()` → empty; `new X(n)` / `new X(...items)` follow the Array constructor.
  def invoke({:global, "Array"}, {:cell, id} = this, args) do
    Process.put({:gg_cellarr, id}, construct({:global, "Array"}, args))
    this
  end
  def invoke({:global, _} = g, {:cell, _} = this, args) do
    case construct(g, args) do
      {:cell, _} = c -> Enum.each(okeys(c), fn k -> oput(this, k, oget(c, k)) end); this
      _ -> this
    end
  end
  def invoke(nc, _this, args) do
    if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP invoke on #{inspect(nc)|>String.slice(0,40)} args=#{inspect(args)|>String.slice(0,50)}")
    guest_error("not a function")
  end

  # ── generators (eager-collect model) ──
  # A generator call runs its body to completion, collecting yields into a frame; the call returns the
  # collected values as an array (iterable by for-of/spread exactly like the lazy protocol for finite,
  # fully-consumed generators — rollup's only uses). Two-way `x = yield` and infinite generators are NOT
  # supported; a frame stack handles generators calling generators.

  def gen_begin, do: Process.put(:gg_genstack, [[] | Process.get(:gg_genstack, [])])
  def gen_yield(v) do
    [h | t] = Process.get(:gg_genstack)
    Process.put(:gg_genstack, [[v | h] | t])
    :undefined
  end
  def gen_yield_star(v) do
    [h | t] = Process.get(:gg_genstack)
    Process.put(:gg_genstack, [Enum.reverse(iter(v)) ++ h | t])
    :undefined
  end
  # An EAGER generator: the body ran to completion collecting its yields; return a proper ITERATOR object (not a
  # bare array) so the explicit protocol — `it.next()` → {value, done}, `.return()`, `Symbol.iterator`, and
  # for-of/spread — all work. (Eager evaluation means two-way `next(v)` can't feed the value back to a paused
  # yield; that needs lazy suspension, a separate/bigger change.)
  def gen_end do
    [h | t] = Process.get(:gg_genstack)
    Process.put(:gg_genstack, t)
    id = __id()
    Process.put({:gg_geniter, id}, {Enum.reverse(h), 0})
    {:geniter, id}
  end

  # a fresh { value, done } result object (immutable direct-term object).
  defp iter_result(value, done?), do: {["value", "done"], %{"value" => value, "done" => done?}}

  # ── closures (handles, never raw funs) ──

  @doc "Register a native closure behind a `{:fun, id}` handle."
  def fun_new(f) when is_function(f, 1) do
    id = __id()
    Process.put(:gg_funs, Map.put(Process.get(:gg_funs), id, f))
    {:fun, id}
  end

  # ── dispatch gate: the ONLY way a guest invokes anything ──

  @doc """
  Call a guest callee with a list of guest args.

  A callee is resolvable ONLY if it is a guest closure handle or a granted host
  capability handle. Anything else is a guest TypeError — NOT a host escape.
  There is no path here from guest data to an arbitrary MFA.
  """
  def call({:fn, f}, args) when is_function(f, 2), do: f.(:undefined, args)

  def call({:fun, id}, args) do
    case Process.get(:gg_funs) |> Map.get(id) do
      f when is_function(f, 1) -> f.(args)
      _ -> guest_error("not a function")
    end
  end

  def call({:host, cap_id}, args), do: host_call(cap_id, args)
  def call(nc, args) do
    if System.get_env("GAPLOG") do
      st = Process.info(self(), :current_stacktrace) |> elem(1) |> Enum.filter(fn {m,_,_,_} -> m |> to_string() |> String.contains?("Guest") end) |> Enum.take(6) |> Enum.map(fn {_,f,a,_} -> "#{f}/#{a}" end)
      IO.puts(:stderr, "GAP call on #{inspect(nc) |> String.slice(0, 40)} args=#{inspect(args) |> String.slice(0, 200)} @ #{Enum.join(st, " <- ")}")
    end
    if System.get_env("GAPSOFT"), do: :undefined, else: guest_error("not a function")
  end

  @doc """
  Invoke a granted host capability by integer id. An id that was not granted is a
  guest TypeError. The capability re-derives its authority from the run context at
  call time — it carries no ambient capability the guest could capture and reuse.
  """
  def host_call(cap_id, args) do
    ctx = Process.get(:gg_ctx)

    case ctx && Map.get(ctx.caps, cap_id) do
      %{fun: f} -> f.(args, ctx)
      _ -> guest_error("not a function")
    end
  end

  # ── arithmetic / comparison (closed, type-checked, no raw host ops on guest data) ──

  # BIGINT: `{:bigint, n}` with n an ARBITRARY-PRECISION Elixir integer. Any op with a bigint operand routes
  # here — bit shifts do NOT truncate to 32 bits (rollup's chunk signatures `atomMask <<= 1n` need full width),
  # division is integer (toward zero). Placed before the number clauses; a bigint is a tuple, not is_number.
  def binop(op, {:bigint, _} = a, b), do: bigint_binop(op, a, b)
  def binop(op, a, {:bigint, _} = b), do: bigint_binop(op, a, b)

  def binop(:+, a, b) when is_number(a) and is_number(b), do: a + b
  # JS `+`: concat only if a STRING is involved; an OBJECT/array ToPrimitive's to a string (`[]+1 === "1"`);
  # otherwise (bool/null/undefined) it's NUMERIC (`true + 1 === 2`, `undefined + 1` is NaN) — was wrongly
  # string-concatenating (`0 + true` gave "0true").
  def binop(:+, a, b) when is_binary(a) or is_binary(b), do: to_str(a) <> to_str(b)
  def binop(:+, a, b) when is_tuple(a) or is_tuple(b), do: to_str(a) <> to_str(b)
  def binop(:+, a, b), do: arith(a, b, &Kernel.+/2)
  def binop(:-, a, b) when is_number(a) and is_number(b), do: a - b
  def binop(:*, a, b) when is_number(a) and is_number(b), do: a * b
  def binop(:/, a, b) when is_number(a) and is_number(b) and b != 0, do: a / b
  # JS division never throws: x/0 = ±Infinity, 0/0 = NaN (acorn's number reader divides by zero on purpose).
  def binop(:/, a, b) do
    na = to_number(a)
    nb = to_number(b)

    cond do
      not is_number(na) or not is_number(nb) -> :nan
      nb != 0 -> na / nb
      na == 0 -> :nan
      na > 0 -> :infinity
      true -> :neg_infinity
    end
  end
  # ±Infinity in relational comparisons (rank-ordered; NaN comparisons are always false, handled by fallback).
  def binop(op, a, b) when op in [:<, :>, :"<=", :">="] and (a == :infinity or a == :neg_infinity or b == :infinity or b == :neg_infinity) do
    case {rel_key(a), rel_key(b)} do
      {nil, _} -> false
      {_, nil} -> false
      {ka, kb} -> case op do
        :< -> ka < kb
        :> -> ka > kb
        :"<=" -> ka <= kb
        :">=" -> ka >= kb
      end
    end
  end

  def binop(:<, a, b) when is_number(a) and is_number(b), do: a < b
  def binop(:>, a, b) when is_number(a) and is_number(b), do: a > b
  def binop(:"<=", a, b) when is_number(a) and is_number(b), do: a <= b
  def binop(:">=", a, b) when is_number(a) and is_number(b), do: a >= b
  # JS `%` is the TRUNCATED remainder (sign follows the dividend): `-1 % 2 === -1`, not floored `1`.
  def binop(:rem, a, b) when is_number(a) and is_number(b) and b != 0, do: a - b * trunc(a / b)
  # string relational comparison (lexicographic, JS semantics)
  def binop(:<, a, b) when is_binary(a) and is_binary(b), do: a < b
  def binop(:>, a, b) when is_binary(a) and is_binary(b), do: a > b
  def binop(:"<=", a, b) when is_binary(a) and is_binary(b), do: a <= b
  def binop(:">=", a, b) when is_binary(a) and is_binary(b), do: a >= b
  def binop(:===, a, b), do: a === b
  def binop(:!==, a, b), do: a !== b
  # loose equality: `null == undefined` is true; number/string/boolean coerce (marked's `x != null` idiom).
  def binop(:==, a, b), do: loose_eq(a, b)
  def binop(:!=, a, b), do: not loose_eq(a, b)
  def binop(:in, k, obj), do: has_own(obj, k)
  # EVERY non-primitive value is `instanceof Object` — all objects inherit Object.prototype. This runtime's
  # user-instance prototype chains don't explicitly terminate at Object.prototype, so answer Object directly
  # (before the constructor-specific clauses) for arrays, functions, cells/user-instances, plain objects, etc.
  def binop(:instanceof, v, {:global, "Object"}), do: object_like?(v)
  # `x instanceof Ctor` — walk x's prototype chain (from `new`/Object.create linkage) for Ctor.prototype.
  def binop(:instanceof, {:cell, id}, {:fn, _} = ctor), do: instanceof_chain(Process.get({:gg_instproto, id}), fn_proto(ctor))
  # instanceof against a built-in constructor: match the cell's `{:proto, name}` chain; every error is also
  # `instanceof Error`.
  def binop(:instanceof, {:cell, id}, {:global, name}) do
    case Process.get({:gg_instproto, id}) do
      {:proto, ^name} -> true
      {:proto, sub} when name == "Error" and sub in @error_names -> true
      proto -> instanceof_chain(proto, {:proto, name})
    end
  end
  def binop(:instanceof, _a, _b), do: false
  # bitwise ops — JS coerces via ToInt32; result is a signed 32-bit int returned as a float.
  def binop(:band, a, b), do: bitop(a, b, &Bitwise.band/2)
  def binop(:bor, a, b), do: bitop(a, b, &Bitwise.bor/2)
  def binop(:bxor, a, b), do: bitop(a, b, &Bitwise.bxor/2)
  def binop(:bsl, a, b), do: bitop(a, b, fn x, y -> Bitwise.bsl(x, Bitwise.band(y, 31)) end)
  def binop(:bsr, a, b), do: bitop(a, b, fn x, y -> Bitwise.bsr(x, Bitwise.band(y, 31)) end)
  # `a >>> b`: ToUint32(a) shifted right by (b & 31), result UNSIGNED (JS's only unsigned op).
  def binop(:bsru, a, b), do: Bitwise.bsr(Bitwise.band(to_int32(a), 0xFFFFFFFF), Bitwise.band(to_int32(b), 31)) * 1.0
  def binop(:pow, a, b), do: arith(a, b, &js_pow/2)

  # JS `**` / Math.pow never throws — Erlang `:math.pow` raises on 0**negative (÷0) and negative**fractional
  # (domain). Map those to the JS results (Infinity / NaN) instead of crashing the runtime.
  defp js_pow(x, y) when is_number(x) and is_number(y) do
    try do
      :math.pow(x, y)
    rescue
      ArithmeticError ->
        cond do
          x == 0 and y < 0 -> :infinity
          x < 0 -> :nan
          true -> :nan
        end
    end
  end

  defp js_pow(_, _), do: :nan
  # relational comparison with a mismatched/non-number operand (`1 < undefined`) is false in JS (NaN).
  def binop(op, _a, _b) when op in [:<, :>, :"<=", :">="], do: false
  # arithmetic on non-number operands: JS coerces via ToNumber; a non-coercible operand yields NaN
  # (`undefined - 2`, `[] * 3`). marked relies on NaN propagating rather than throwing.
  def binop(:-, a, b), do: arith(a, b, &Kernel.-/2)
  def binop(:*, a, b), do: arith(a, b, &Kernel.*/2)
  def binop(:rem, a, b), do: arith(a, b, fn x, y -> if y == 0, do: :nan, else: x - y * trunc(x / y) end)
  def binop(op, a, b) do
    if System.get_env("GAPLOG"), do: IO.puts(:stderr, "GAP binop #{inspect(op)} a=#{inspect(a)|>String.slice(0,30)} b=#{inspect(b)|>String.slice(0,30)}")
    guest_error("bad operands")
  end

  # bigint arithmetic/bitwise/comparison. `+` with a string concatenates (JS `1n + "x"` → "1x"); everything
  # else works on the integer values (a number operand is truncated to an integer — F2 is permissive where JS
  # would throw on mixed bigint/number, since the rollup path is all-bigint). === is strict (both must be
  # bigint); == is loose value equality across bigint/number/string.
  defp bigint_binop(:+, a, b) when is_binary(a) or is_binary(b), do: to_str(a) <> to_str(b)

  defp bigint_binop(op, a, b) do
    both_bi? = match?({:bigint, _}, a) and match?({:bigint, _}, b)
    x = bi_int(a)
    y = bi_int(b)

    case op do
      :+ -> {:bigint, x + y}
      :- -> {:bigint, x - y}
      :* -> {:bigint, x * y}
      :/ -> if y == 0, do: guest_error("Division by zero"), else: {:bigint, div(x, y)}
      :rem -> if y == 0, do: guest_error("Division by zero"), else: {:bigint, rem(x, y)}
      :pow -> if y < 0, do: guest_error("Exponent must be non-negative"), else: {:bigint, Integer.pow(x, y)}
      :band -> {:bigint, Bitwise.band(x, y)}
      :bor -> {:bigint, Bitwise.bor(x, y)}
      :bxor -> {:bigint, Bitwise.bxor(x, y)}
      # arbitrary-precision shifts — NO 32-bit mask (rollup's `atomMask <<= 1n` past bit 31).
      :bsl -> {:bigint, Bitwise.bsl(x, y)}
      :bsr -> {:bigint, Bitwise.bsr(x, y)}
      :< -> x < y
      :> -> x > y
      :"<=" -> x <= y
      :">=" -> x >= y
      :=== -> both_bi? and x == y
      :!== -> not (both_bi? and x == y)
      :== -> x == y
      :!= -> x != y
      _ -> guest_error("bad operands")
    end
  end

  # integer value of a bigint / number / bool for bigint math (JS would throw on a non-integer number operand;
  # F2 truncates).
  defp bi_int({:bigint, n}), do: n
  defp bi_int(n) when is_integer(n), do: n
  # NumberToBigInt: a non-integral number (incl. NaN/Infinity, which arrive as :nan/:infinity atoms) is a
  # RangeError, not a truncation.
  defp bi_int(n) when is_float(n) do
    if n == trunc(n) * 1.0, do: trunc(n), else: throw({:gg_throw, mk_error("RangeError", "The number #{n} cannot be converted to a BigInt because it is not an integer")})
  end
  defp bi_int(a) when a in [:nan, :infinity, :neg_infinity], do: throw({:gg_throw, mk_error("RangeError", "The number cannot be converted to a BigInt because it is not an integer")})
  defp bi_int(true), do: 1
  defp bi_int(false), do: 0
  defp bi_int(s) when is_binary(s), do: bi_str(s)
  # BigInt(obj): ToPrimitive first (Symbol.toPrimitive → valueOf → toString), then coerce the primitive.
  defp bi_int({:cell, _} = o), do: bi_int(to_primitive(o))
  defp bi_int(_), do: 0

  # a bigint string literal: empty → 0, radix prefixes 0x/0o/0b, else decimal (all whitespace-trimmed).
  defp bi_str(s) do
    t = String.trim(s)

    cond do
      t == "" -> 0
      String.match?(t, ~r/^0[xX][0-9a-fA-F]+$/) -> String.to_integer(String.slice(t, 2..-1//1), 16)
      String.match?(t, ~r/^0[oO][0-7]+$/) -> String.to_integer(String.slice(t, 2..-1//1), 8)
      String.match?(t, ~r/^0[bB][01]+$/) -> String.to_integer(String.slice(t, 2..-1//1), 2)
      true -> (case Integer.parse(t) do {i, ""} -> i; _ -> 0 end)
    end
  end

  # ToPrimitive(obj, "number"/"default"): Symbol.toPrimitive, then valueOf, then toString — the first that
  # returns a non-object primitive wins.
  defp to_primitive({:cell, _} = o) do
    Enum.reduce_while(["@@sym:@@toPrimitive", "valueOf", "toString"], :undefined, fn m, _ ->
      f = oget(o, m)

      case (if match?({:fn, _}, f) or match?({:host, _}, f), do: invoke(f, o, []), else: :__skip) do
        {:cell, _} -> {:cont, :undefined}
        :__skip -> {:cont, :undefined}
        prim -> {:halt, prim}
      end
    end)
  end

  defp to_primitive(v), do: v

  defp nullish?(:null), do: true
  defp nullish?(:undefined), do: true
  defp nullish?(_), do: false

  defp loose_eq(a, b) do
    cond do
      a === b -> true
      nullish?(a) and nullish?(b) -> true
      is_number(a) and is_binary(b) -> (n = to_number(b); is_number(n) and a === n)
      is_binary(a) and is_number(b) -> (n = to_number(a); is_number(n) and n === b)
      is_boolean(a) -> loose_eq((if a, do: 1.0, else: 0.0), b)
      is_boolean(b) -> loose_eq(a, (if b, do: 1.0, else: 0.0))
      # object vs primitive: ToPrimitive the object (array → its join string, {} → "[object Object]") and retry
      # (`[] == 0` is true: "" → 0 == 0).
      obj?(a) and (is_number(b) or is_binary(b)) -> loose_eq(prim_of(a), b)
      obj?(b) and (is_number(a) or is_binary(a)) -> loose_eq(a, prim_of(b))
      true -> false
    end
  end

  defp obj?({:arr, _}), do: true
  defp obj?({:cell, _}), do: true
  defp obj?(_), do: false
  defp prim_of({:arr, _} = a), do: to_str(a)
  defp prim_of({:cell, _} = c), do: to_primitive(c)

  defp to_int32(v) do
    n = trunc(num(v))
    m = rem(n, 4_294_967_296)
    m = if m < 0, do: m + 4_294_967_296, else: m
    if m >= 2_147_483_648, do: m - 4_294_967_296, else: m
  end

  defp bitop(a, b, f), do: to_int32(f.(to_int32(a), to_int32(b))) * 1.0

  defp rel_key(:infinity), do: {2, 0}
  defp rel_key(:neg_infinity), do: {0, 0}
  defp rel_key(x) when is_number(x), do: {1, x}
  defp rel_key(_), do: nil

  defp arith(a, b, f) do
    na = to_number(a)
    nb = to_number(b)
    cond do
      is_number(na) and is_number(nb) -> f.(na, nb)
      # 0 - (±Infinity) negates it (covers unary minus); anything else with an infinity stays infinite/NaN.
      a == 0.0 and nb == :infinity -> :neg_infinity
      a == 0.0 and nb == :neg_infinity -> :infinity
      true -> :nan
    end
  end

  @doc "JS nullish: only null/undefined (for `??` and `?.`). Distinct from falsy."
  def is_nullish(:undefined), do: true
  def is_nullish(:null), do: true
  def is_nullish(_), do: false

  def truthy(false), do: false
  def truthy(:undefined), do: false
  def truthy(:null), do: false
  def truthy(0), do: false
  def truthy(+0.0), do: false
  def truthy(""), do: false
  def truthy({:bigint, 0}), do: false
  def truthy(:nan), do: false
  def truthy(_), do: true

  # ── helpers ──

  # Guest property keys are always binaries. A guest never produces an atom key,
  # and we never atomize a guest string — this is the atom-domain firewall.
  defp key_str(k) when is_binary(k), do: k
  defp key_str({:bigint, n}), do: Integer.to_string(n)
  defp key_str(k) when is_number(k), do: to_str(k)
  defp key_str(true), do: "true"
  defp key_str(false), do: "false"
  defp key_str(:undefined), do: "undefined"
  defp key_str(:null), do: "null"
  # a symbol used as a property key: tag uniquely by its identity so distinct symbols don't collide.
  defp key_str({:symbol, id, _desc}), do: "@@sym:" <> to_string(id)
  defp key_str(_), do: "[object]"

  @doc "Stringify a guest value for output (spike formatting; byte-exact dtoa is a separate layer)."
  def to_str(v) when is_binary(v), do: v
  # a bigint stringifies as the plain integer (no `n` suffix): String(5n) === "5".
  def to_str({:bigint, n}), do: Integer.to_string(n)
  def to_str(v) when is_integer(v), do: Integer.to_string(v)

  def to_str(v) when is_float(v), do: js_float_str(v)

  # ECMAScript Number::toString — the shortest round-tripping decimal (Erlang `:short` dtoa) reformatted to JS's
  # fixed/exponential rules (which differ from Elixir's Float.to_string). E.g. 1e30 → "1e+30" (not the full
  # integer), 0.0009765625 → fixed (not "9.765625e-4"), 1e21 → "1e+21" but 1e20 → "100000000000000000000".
  defp js_float_str(v) when v == 0.0, do: "0"

  defp js_float_str(v) do
    {neg, body} = case :erlang.float_to_binary(v, [:short]) do "-" <> rest -> {true, rest}; s -> {false, s} end
    {mant, e} = case String.split(body, "e") do [m, ex] -> {m, String.to_integer(ex)}; [m] -> {m, 0} end
    {int, frac} = case String.split(mant, ".") do [i, f] -> {i, f}; [i] -> {i, ""} end
    digits0 = int <> frac
    m0 = String.to_integer(digits0)

    if m0 == 0 do
      "0"
    else
      # value = m0 × 10^p; normalise m0 to have no trailing zeros → significant digits s, point position n.
      {m, p} = strip_trailing_zeros(m0, String.length(int) + e - String.length(digits0))
      s = Integer.to_string(m)
      k = String.length(s)
      n = p + k
      out = ecma_notation(s, k, n)
      if neg, do: "-" <> out, else: out
    end
  end

  defp strip_trailing_zeros(m, p) when rem(m, 10) == 0, do: strip_trailing_zeros(div(m, 10), p + 1)
  defp strip_trailing_zeros(m, p), do: {m, p}

  # `s` = k significant digits, decimal point after `n` (value = s × 10^(n-k)).
  defp ecma_notation(s, k, n) do
    cond do
      # integer with no fractional part, exponent ≤ 21: digits then trailing zeros.
      n >= k and n <= 21 -> s <> String.duplicate("0", n - k)
      # a decimal point falls inside the digits.
      n > 0 and n <= 21 -> String.slice(s, 0, n) <> "." <> String.slice(s, n, k - n)
      # small magnitude: "0.00…" then the digits.
      n > -6 and n <= 0 -> "0." <> String.duplicate("0", -n) <> s
      # everything else: exponential `d[.rest]e±E`, E = n-1.
      true ->
        e_out = n - 1
        first = String.slice(s, 0, 1)
        mant = if k > 1, do: first <> "." <> String.slice(s, 1, k - 1), else: first
        mant <> "e" <> (if e_out >= 0, do: "+", else: "-") <> Integer.to_string(abs(e_out))
    end
  end

  def to_str(true), do: "true"
  def to_str(false), do: "false"
  def to_str(:undefined), do: "undefined"
  def to_str(:null), do: "null"
  def to_str({:symbol, _, desc}), do: "Symbol(" <> desc <> ")"
  def to_str({:obj, _}), do: "[object Object]"
  def to_str({:fun, _}), do: "function"
  def to_str({:host, _}), do: "function"
  def to_str({t, _} = a) when t in [:arr, :al], do: al(a) |> Enum.map(fn v -> if v in [:undefined, :null], do: "", else: to_str(v) end) |> Enum.join(",")
  def to_str({:regex, _, src, flags}), do: "/" <> src <> "/" <> flags
  def to_str({:fn, _}), do: "function"
  def to_str({:date, _} = d), do: method(d, "toString", [])
  def to_str({:bytes, b}), do: b
  def to_str({:proxy, t, _}), do: to_str(t)
  # a cell: honor a guest `toString`, else Error-shape (`Name: message`), else the object tag.
  def to_str({:cell, _} = c) do
    cond do
      match?({:fn, _}, oget(c, "toString")) -> to_str(invoke(oget(c, "toString"), c, []))
      oget(c, "message") != :undefined or oget(c, "name") != :undefined ->
        nm = case oget(c, "name") do :undefined -> "Error"; n -> to_str(n) end
        case oget(c, "message") do :undefined -> nm; "" -> nm; m -> nm <> ": " <> to_str(m) end
      true -> "[object Object]"
    end
  end
  def to_str(:infinity), do: "Infinity"
  def to_str(:neg_infinity), do: "-Infinity"
  def to_str(:nan), do: "NaN"
  def to_str(_), do: "[unknown]"

  defp set_list({:set, id}), do: Process.get({:gg_set, id}, [])
  defp map_pairs({:map, id}), do: Process.get({:gg_map, id}, [])

  defp to_string_tag(x) do
    tag =
      cond do
        is_number(x) -> "Number"
        is_binary(x) -> "String"
        is_boolean(x) -> "Boolean"
        x == :undefined -> "Undefined"
        x == :null -> "Null"
        match?({:arr, _}, x) -> "Array"
        match?({:regex, _, _, _}, x) -> "RegExp"
        match?({:fn, _}, x) or match?({:host, _}, x) or match?({:globalfn, _}, x) -> "Function"
        true -> "Object"
      end
    "[object " <> tag <> "]"
  end

  defp has_own(o, k) do
    key = key_str(k)
    case o do
      {:cell, _} -> Map.has_key?(cell_read(o) |> elem(1), key)
      {:fn, f} ->
        (Process.get(:gg_fnprops, %{}) |> Map.get(f, {[], %{}}) |> elem(1) |> Map.has_key?(key)) or
          (key in ["name", "length"] and not fn_deleted?(f, key))
      {keys, map} when is_map(map) -> Map.has_key?(map, key)
      {:globalobj} -> Process.get(:gg_global, {[], %{}}) |> elem(1) |> Map.has_key?(key)
      {:arr, _} = a -> len = length(al(a)); key == "length" or match?({n, ""} when n >= 0 and n < len, Integer.parse(key))
      _ -> false
    end
  end

  @doc "A guest-level exception. NOT a host escape — the driver catches it as a guest error."
  def guest_error(reason) do
    if System.get_env("GAPTRACE") do
      st = Process.info(self(), :current_stacktrace) |> elem(1)
           |> Enum.filter(fn {m,_,_,_} -> m |> to_string() =~ ~r/Runtime|Guest/ end) |> Enum.take(8)
      IO.puts(:stderr, "GERR #{inspect(reason)}: #{Enum.map_join(st, " <- ", fn {_,f,a,_} -> "#{f}/#{a}" end)}")
    end

    # GGPOS=1: Walk stamps the current statement's source byte offset — the error names WHERE in the guest.
    case Process.get(:gg_pos) do
      nil -> :ok
      pos -> if System.get_env("GGPOS"), do: IO.puts(:stderr, "GPOS #{inspect(reason)} @ byte #{pos}")
    end

    throw({:gg_guest_error, reason})
  end

  @doc "Throw a real TypeError OBJECT (not a bare string) so a guest `catch(e)` sees `e instanceof TypeError`
  and `e.constructor === TypeError` (test262's assert.throws checks constructor identity)."
  def type_error(msg) do
    if System.get_env("TETRACE"), do: IO.puts(:stderr, "TE @#{inspect(Process.get(:gg_pos))} #{msg}")
    throw({:gg_throw, mk_error("TypeError", msg)})
  end

  @doc """
  Temporal-dead-zone guard: a `let`/`const` binding read BEFORE its declaration executes throws a ReferenceError
  (JS semantics). Lexical bindings are hoisted to the `:gg_tdz` poison; the declaration overwrites it with the
  real value, so a normal read (after init) passes straight through. `:gg_tdz` is not a producible guest value,
  so this can never false-positive on real data.
  """
  def tdz(:gg_tdz, name), do: throw({:gg_throw, mk_error("ReferenceError", "Cannot access '#{name}' before initialization")})
  def tdz(v, _name), do: v

  # soft TDZ guard: a let/const read across a FUNCTION boundary (an inner closure reading an outer lexical).
  # Whether this is a real dead-zone error depends on WHEN the closure runs relative to the outer declaration,
  # which the eager promise model collapses into drain depth: invoked synchronously (an IIFE during the
  # initializer, in_async_continuation? == false) it IS a temporal-dead-zone error and throws; invoked by the
  # async machinery after the sync frame initializes the binding (a `.then`/`await`/`setTimeout` callback) it
  # is a legit late read and degrades to :undefined. Either way the raw :gg_tdz sentinel never leaks out.
  def tdz_soft(:gg_tdz, name), do: (if in_async_continuation?(), do: :undefined, else: tdz(:gg_tdz, name))
  def tdz_soft(v, _name), do: v

  @doc "Guest `return` — throws to the enclosing function-body catch. Routed through the Runtime so the
  emitted guest module references no external module (keeps the 'only Runtime' confinement invariant literal)."
  def ret(v), do: throw({:gg_return, v})

  @doc "Read/write an UNDECLARED identifier — a JS implicit global (`i = 5` with no `var` targets globalThis).
  Both go through the guest-owned global object, so reads and writes agree (Lower's fallback formerly wrote a
  local lvar but read undefined). gset returns the value so `x = (i = 5)` yields 5."
  def gget(name), do: oget({:globalobj}, name)
  def gset(name, val), do: (oput({:globalobj}, name, val); val)

  @doc "Short-circuit an optional chain (`a?.b.c` with nullish `a`) — thrown from a nullish optional link and
  caught at the ChainExpression boundary, yielding undefined for the WHOLE chain. Routed through the Runtime so
  the emitted guest code never contains a bare `throw` (keeps the 'only Runtime' + pre-compile-audit invariant)."
  def optchain_miss, do: throw({:gg_optchain})

  @doc "Loop break/continue — routed through the Runtime so the guest references no :erlang.throw (confinement)."
  def brk(tag), do: throw({:gg_break, tag})
  def cont(tag), do: throw({:gg_continue, tag})

  # GGFUEL=1: per-loop iteration counter that aborts a runaway loop, naming its source byte — pinpoints a
  # loop that terminates in Walk but spins in the compiled lane (loop var not threaded/boxed). No-op unless set.
  def loop_tick(pos) do
    n = Process.get({:gg_fuel, pos}, 0) + 1
    Process.put({:gg_fuel, pos}, n)
    cap = Process.get(:gg_fuel_cap, 5_000_000)
    if n > cap, do: throw({:gg_guest_error, "loop fuel exhausted @ byte #{pos} (#{n} iters)"})
    :ok
  end

  @doc "GGFUEL: global guest-call counter — catches runaway RECURSION (a function that self-calls forever
  in the compiled lane but terminates in Walk). Aborts past the cap. No-op unless armed."
  def call_tick do
    n = Process.get(:gg_calls, 0) + 1
    Process.put(:gg_calls, n)
    cap = Process.get(:gg_call_cap, 50_000_000)

    if n > cap do
      top =
        Process.get(:gg_fnhits, %{})
        |> Enum.sort_by(fn {_, c} -> -c end)
        |> Enum.take(12)
        |> Enum.map(fn {pos, c} -> "byte #{pos}: #{c}" end)

      IO.puts(:stderr, "CALLFUEL hottest functions:\n  " <> Enum.join(top, "\n  "))
      throw({:gg_guest_error, "call fuel exhausted (#{n} calls)"})
    end

    :ok
  end

  @doc "GGFUEL: per-function-source-position call tally (armed by :gg_fuel_on) — names the runaway function."
  def fn_tick(pos) do
    Process.put(:gg_fnhits, Map.update(Process.get(:gg_fnhits, %{}), pos, 1, &(&1 + 1)))
    :ok
  end

  @doc "Guest `throw e` — a catchable guest exception carrying the guest value."
  def throw_val(v), do: throw({:gg_throw, v})

  @doc "for-of iteration items: array elements, or a string's chars (1-char binaries)."
  def iter({t, _} = a) when t in [:arr, :al], do: al(a)
  # spread/for-of over a generator consumes its REMAINING values (from the current cursor position).
  def iter({:geniter, id}) do
    {list, pos} = Process.get({:gg_geniter, id}, {[], 0})
    Process.put({:gg_geniter, id}, {list, length(list)})
    Enum.drop(list, pos)
  end
  # a cell backed by a real array (class extends Array) iterates its elements (for-of / spread over a NodeList).
  def iter({:cell, id}) do
    case Process.get({:gg_cellarr, id}) do
      nil -> []
      arr -> al(arr)
    end
  end
  def iter({:set, _} = st), do: set_list(st)
  def iter({:ta, _, _, _, _} = ta), do: ta_elems(ta)
  def iter({:map, _} = mp), do: Enum.map(map_pairs(mp), fn {k, v} -> avec([k, v]) end)
  def iter(s) when is_binary(s), do: for <<c::utf8 <- s>>, do: <<c::utf8>>
  def iter(_), do: []

  # ── LIVE iteration cursors (for-of) ──────────────────────────────────────────────────────────────────────
  # JS iterators over Set/Map/Array observe entries APPENDED during the loop — rollup grows a Set while
  # iterating it in four places (`for (const m of staticDependencies) { staticDependencies.add(dep) }` is how
  # the chunk graph closes over dependencies). A snapshot iterator silently truncates the walk, so for-of in
  # both lanes steps through these cursors, re-reading the collection each step. Other iterables (strings,
  # typed arrays) keep snapshot semantics.
  def iter_start({t, _} = a) when t in [:arr, :al], do: {:gg_acur, a, 0}
  def iter_start({:geniter, _} = g), do: {:gg_gcur, g}
  def iter_start({:set, id}), do: {:gg_scur, id, 0}
  def iter_start({:map, id}), do: {:gg_mcur, id, 0}
  def iter_start(other), do: {:gg_lcur, iter(other)}

  def iter_next({:gg_acur, a, i}) do
    l = al(a)
    if i < length(l), do: {Enum.at(l, i), {:gg_acur, a, i + 1}}, else: :done
  end

  # generator cursor — advances the shared {:gg_geniter} position, so for-of and explicit .next() stay in sync.
  def iter_next({:gg_gcur, {:geniter, id} = g}) do
    {list, pos} = Process.get({:gg_geniter, id}, {[], 0})

    if pos < length(list) do
      Process.put({:gg_geniter, id}, {list, pos + 1})
      {Enum.at(list, pos), {:gg_gcur, g}}
    else
      :done
    end
  end

  def iter_next({:gg_scur, id, i}) do
    l = set_list({:set, id})
    if i < length(l), do: {Enum.at(l, i), {:gg_scur, id, i + 1}}, else: :done
  end

  def iter_next({:gg_mcur, id, i}) do
    l = map_pairs({:map, id})

    case Enum.at(l, i) do
      nil -> :done
      {k, v} -> {avec([k, v]), {:gg_mcur, id, i + 1}}
    end
  end

  def iter_next({:gg_lcur, []}), do: :done
  def iter_next({:gg_lcur, [h | t]}), do: {h, {:gg_lcur, t}}

  @doc "for-in cursor: snapshot of enumerable keys (JS for-in does not guarantee live additions)."
  def keys_cursor(o), do: {:gg_lcur, enum_keys(o)}

  @doc "for-in enumeration keys: object own-keys, array index strings, or none."
  def enum_keys({keys, map}) when is_map(map), do: keys
  # for-in enumerates ENUMERABLE own keys (a defineProperty non-enumerable prop is skipped, like Object.keys).
  def enum_keys({:cell, _} = c), do: (cell_read(c) |> elem(0) |> Enum.filter(&prop_enumerable?(c, &1)))
  def enum_keys({t, _} = a) when t in [:arr, :al], do: (l = al(a); if l == [], do: [], else: Enum.map(0..(length(l) - 1)//1, &Integer.to_string/1))
  def enum_keys(_), do: []

  @doc "`typeof` — a fixed set of result binaries (never guest-controlled atoms)."
  def typeof({:bigint, _}), do: "bigint"
  def typeof(v) when is_number(v), do: "number"
  def typeof(v) when is_binary(v), do: "string"
  def typeof(v) when is_boolean(v), do: "boolean"
  def typeof(:undefined), do: "undefined"
  def typeof({:fn, _}), do: "function"
  def typeof({:host, _}), do: "function"
  def typeof({:cell, _}), do: "object"
  def typeof({:globalobj}), do: "object"
  def typeof({:regex, _, _, _}), do: "object"
  def typeof({:global, _}), do: "function"
  def typeof({:globalfn, _}), do: "function"
  def typeof(:infinity), do: "number"
  def typeof(:neg_infinity), do: "number"
  def typeof(:nan), do: "number"
  def typeof(:null), do: "object"
  def typeof({:symbol, _, _}), do: "symbol"
  def typeof({:promise, _}), do: "object"
  def typeof({:bytes, _}), do: "object"
  def typeof({:proxy, t, _}), do: typeof(t)
  def typeof({:date, _}), do: "object"
  def typeof({:ta, _, _, _, _}), do: "object"
  def typeof({:abuf, _, _}), do: "object"
  def typeof({:dataview, _, _, _}), do: "object"
  def typeof({:textdecoder}), do: "object"
  def typeof({:textencoder}), do: "object"
  def typeof(_), do: "object"

  # ── DoS primitives (emitted only for the red-team's containment tests) ──

  @doc "Unbounded CPU: tail loop, never returns. Contained by the run process timeout."
  def spin, do: spin()

  @doc "Unbounded memory: accumulate on-heap terms. Contained by the process max_heap_size{kill}."
  def mem_bomb(acc \\ []), do: mem_bomb([:lists.seq(1, 500) | acc])

  # ── host capabilities (the ENTIRE allowed side-effect surface) ──
  # Each is `fn args, ctx -> guest_value`. Tenant authority comes from ctx, fresh per call.

  @doc "cap: print — append to the run output buffer."
  def cap_print(args, _ctx) do
    s = args |> Enum.map(&to_str/1) |> Enum.join(" ")
    Process.put(:gg_out, [s | Process.get(:gg_out, [])])
    :undefined
  end

  @doc "cap: fs_read — read a path, CONFINED to the tenant root. Traversal/absolute escapes denied."
  def cap_fs_read([path | _], ctx) when is_binary(path) do
    case confine(ctx.tenant_root, path) do
      {:ok, key} -> Map.get(ctx.fs, key, :undefined)
      :denied -> :undefined
    end
  end

  def cap_fs_read(_args, _ctx), do: :undefined

  @doc "cap: fs_write — write a path, CONFINED to the tenant root."
  def cap_fs_write([path, data | _], ctx) when is_binary(path) do
    case confine(ctx.tenant_root, path) do
      {:ok, key} ->
        # In production this delegates to Nexus.Wasm.VFS (tenant-partitioned Store).
        # Here we record the write on the ctx's fs-writes log so the red-team can assert
        # exactly which keys a guest managed to write — and that traversal never escapes.
        log = Process.get(:gg_fs_writes, [])
        Process.put(:gg_fs_writes, [{key, to_str(data)} | log])
        :undefined

      :denied ->
        :undefined
    end
  end

  def cap_fs_write(_args, _ctx), do: :undefined

  @doc """
  cap: eval — parse a guest string and run it through the CONFINED INTERPRETER (not the
  compiler). Eval'd code inherits exactly the parent's grant (`ctx`), never more, and is
  confined identically (an ungranted identifier is `:undefined`). Interpreting rather than
  compiling avoids minting atoms per eval — closing the eval-driven atom-exhaustion DoS.
  A guest-level error inside eval'd code propagates as the run's guest error.
  """
  def cap_eval([src | _], ctx) when is_binary(src) do
    ast = TinyLasers.Gate.Parser.parse(src)
    TinyLasers.Gate.Interp.run(ast, ctx)
  catch
    :throw, {:gg_parse, _reason} -> guest_error("eval parse error")
  end

  def cap_eval(_args, _ctx), do: :undefined

  # Path confinement: resolve `path` under `root`, reject anything that escapes it.
  defp confine(root, path) do
    full = Path.expand(path, root)

    if full == root or String.starts_with?(full, root <> "/") do
      {:ok, full}
    else
      :denied
    end
  end
end
