# WebAssembly Text Format (WAT) Advent of Code solutions

These are my solvers for [Advent of Code](https://adventofcode.com/) challenges, written in WebAssembly Text Format (WAT), for some godforsaken reason.

The solvers only use native WebAssembly instructions and WASI snapshot preview 1 calls (for I/O), no other external linking.

# How to run

The solvers expect an input.txt file in the directory passed as the preopened directory, and will print the answer to STDOUT. The directory can be anywhere, but for convenience is the same directory as the solver in this repo.

If the requirements are satisfied, the solvers should work in any runtime, but the easiest way to run these is to use [wasmtime](https://wasmtime.dev/). Install it and then run a single solution like so:

```bash
wasmtime run --dir=2019/day1/ 2019/day1/read_file.wat
```
