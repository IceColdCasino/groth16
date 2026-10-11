# Benchmark Circuits for GPU Prover

This directory contains documentation and tooling for generating test circuits used to benchmark the GPU-accelerated prover against the CPU baseline (rapidsnark).

## Circuit Sizes

We benchmark four circuit sizes to evaluate GPU vs CPU performance across a range of constraint counts:

| Size      | Constraints | Status     | Source                                    |
|-----------|-------------|------------|-------------------------------------------|
| small     | ~1K         | Available  | `../rapidsnark/testdata/`                 |
| medium    | ~100K       | Needed     | Generated via `generate_circuits.sh`      |
| large     | ~1M         | Needed     | Generated via `generate_circuits.sh`      |
| xlarge    | ~10M        | Needed     | Generated via `generate_circuits.sh`      |

## Expected File Format

Each benchmark circuit requires two files:

- **`.zkey`** — Proving key (finalized phase 2 trusted setup)
- **`.wtns`** — Witness file for a specific input instance

These files should be placed in `prover/benchmarks/circuits/<size>/`:

```
circuits/
  small/
    circuit_final.zkey
    witness.wtns
  medium/
    circuit_final.zkey
    witness.wtns
  large/
    circuit_final.zkey
    witness.wtns
  xlarge/
    circuit_final.zkey
    witness.wtns
```

## Reference: Existing Small Circuit

The small circuit is reused from rapidsnark's testdata:

- **Path**: `../rapidsnark/testdata/circuit_final.zkey` (466 KB)
- **Witness**: `../rapidsnark/testdata/witness.wtns` (31 KB)
- **CPU proving time**: ~37 ms

## Generating Larger Circuits

Larger circuits must be generated with [Circom](https://docs.circom.io/) and snarkjs. See `generate_circuits.sh` for the full workflow.

**Prerequisites**:
- Node.js 18+
- [circom](https://github.com/iden3/circom) installed (`cargo install circom`)
- [snarkjs](https://github.com/iden3/snarkjs) installed (`npm install -g snarkjs`)

**Quickstart**:
```bash
cd prover/benchmarks
./generate_circuits.sh
```

This will generate all four circuit sizes in `circuits/`.

## Benchmarking

Once all circuits are generated, run the prover benchmark:

```bash
cd prover
zig build bench
./zig-out/bin/bench
```

To compare GPU vs CPU for a specific circuit:

```bash
./zig-out/bin/prover --cpu circuits/medium/circuit_final.zkey circuits/medium/witness.wtns
./zig-out/bin/prover --metal circuits/medium/circuit_final.zkey circuits/medium/witness.wtns
```
