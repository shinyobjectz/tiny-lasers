// hello_bridge.go — the __host bridge ABI reference guest, Go edition (docs/host-bridge-abi.md §5b, §2).
//
// Same protocol as hello_bridge.c, proving a THIRD toolchain (tinygo → wasm32-wasi core module) joins the
// contract with zero substrate changes: //go:wasmimport binds host_call directly; //go:wasmexport exposes
// the typed entry. Output must be byte-identical to the C guest for the same input.
//
// Build (committed fixture; rebuild only when the contract changes):
//   tinygo build -o hello_bridge_go.wasm -target=wasip1 -buildmode=c-shared -no-debug hello_bridge.go
package main

import "unsafe"

//go:wasmimport env host_call
func hostCall(namePtr unsafe.Pointer, nameLen uint32, argsPtr unsafe.Pointer, argsLen uint32, outPtr unsafe.Pointer, outCap uint32) uint32

// static arena so returned pointers stay stable (mirrors the C guest's bump allocator)
var heap [65536]byte
var hp uint32

//go:wasmexport tl_alloc
func tlAlloc(n uint32) uint32 {
	p := uint32(uintptr(unsafe.Pointer(&heap[hp])))
	hp = (hp + n + 7) &^ 7
	return p
}

//go:wasmexport run
func run(inPtr unsafe.Pointer, inLen uint32) uint64 {
	in := unsafe.Slice((*byte)(inPtr), inLen)

	// args JSON: ["<input>"] — test inputs carry no quotes/backslashes (§2; real backends emit a full encoder)
	args := make([]byte, 0, inLen+4)
	args = append(args, '[', '"')
	args = append(args, in...)
	args = append(args, '"', ']')

	name := []byte("echo_up")
	var out [4096]byte
	rl := hostCall(unsafe.Pointer(&name[0]), uint32(len(name)),
		unsafe.Pointer(&args[0]), uint32(len(args)),
		unsafe.Pointer(&out[0]), uint32(len(out)))

	// result = "<input>|<host result sans JSON quotes>"
	res := heap[hp:hp]
	res = append(res, in...)
	res = append(res, '|')
	if rl > 2 {
		res = append(res, out[1:rl-1]...)
	}
	ptr := uint32(uintptr(unsafe.Pointer(&res[0])))
	return uint64(ptr)<<32 | uint64(len(res))
}

func main() {} // reactor build; entry is the exports
