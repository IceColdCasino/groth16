# groth16

Groth16 proving and proving-key setup for macOS. `libgroth16` is a drop-in for `librapidsnark`: the same `groth16_*` C entry points, the same JSON proof and public inputs, the same return codes. `zkey` is a drop-in for snarkjs `zkey` setup, contribute, and verification-key export.

The default path runs Zig on the CPU and Metal on the GPU at the same time. Measured on an Apple M1 Max (10 CPU cores, 32 GPU cores, 64 GB), quiet machine, second run.

## Install

The stable formula downloads the Apple Silicon archive from the [0.1.0 GitHub release](https://github.com/IceColdCasino/groth16/releases/tag/v0.1.0). That install does not need Zig or Xcode. macOS 14 or newer is required. A Linux package is not available yet.

```sh
brew trust --tap IceColdCasino/groth16
brew tap IceColdCasino/groth16 https://github.com/IceColdCasino/groth16
brew install icecoldcasino/groth16/zkey
```

`brew install` puts these files on disk:

| File | Path |
|---|---|
| `zkey` | `$(brew --prefix zkey)/bin/zkey` |
| `prover` | `$(brew --prefix zkey)/bin/prover` |
| `bn254.metallib` | next to the `zkey` binary |
| `libgroth16.dylib` | `$(brew --prefix zkey)/lib/libgroth16.dylib` |
| `libgroth16.a` | `$(brew --prefix zkey)/lib/libgroth16.a` |
| `groth16.h` | `$(brew --prefix zkey)/include/groth16.h` |

`brew install` prints those paths. `zkey lib` prints the shared library and the flags to link it:

```text
/opt/homebrew/opt/zkey/lib/libgroth16.dylib
-L/opt/homebrew/opt/zkey/lib -lgroth16 -I/opt/homebrew/opt/zkey/include
```

The first line is the only thing on stdout, so `zkey lib` can be used from a script.

The 0.1.0 archive is the Metal build. `--HEAD` builds main with Zig 0.17 and Xcode. Add `--with-vulkan` on that path to install glslang and MoltenVK and pass `-Dvulkan=true`:

```sh
brew install --HEAD icecoldcasino/groth16/zkey
brew install --HEAD --with-vulkan icecoldcasino/groth16/zkey
```

### From source

```sh
git clone https://github.com/IceColdCasino/groth16.git
cd groth16
zig build -Doptimize=ReleaseFast
(cd zkey-setup && zig build -Doptimize=ReleaseFast --prefix "$PWD/../zig-out")
```

That build uses Metal on macOS and does not call glslang or MoltenVK. Add `-Dvulkan=true` when those two are installed and you want the Vulkan backend.

`zig-out/lib/libgroth16.dylib`, `zig-out/include/groth16.h`, and `zig-out/bin/zkey` are the same three artifacts. `zkey lib` resolves the library from the binary’s install prefix (`bin/../lib/libgroth16.dylib`).

```sh
zig build test -Doptimize=ReleaseFast
(cd zkey-setup && zig build test -Doptimize=ReleaseFast)
```

## Link it where librapidsnark was

`include/groth16.h` declares the same prover and verifier entry points. Load `libgroth16.dylib` anywhere a program `dlopen`s `librapidsnark.dylib`.

```c
groth16_prover_create(&obj, zkey, zkey_size, err, err_cap);
groth16_prover_prove(obj, wtns, wtns_size, proof, &proof_size, pub, &pub_size, err, err_cap);
groth16_prover_destroy(obj);
groth16_verify(proof_json, public_json, vk_json, err, err_cap);
```

`groth16_verify` takes null-terminated JSON in the order proof, public inputs, verification key. It returns `0` valid, `1` invalid, `2` error. `groth16_prover_destroy` frees the caller’s zkey allocation. A failed `groth16_prover_create` leaves that buffer with the caller.

One-shot `groth16_prover` and `groth16_prover_zkey_file` consume the zkey malloc either way.

There is also a `prover` CLI:

```sh
prover <file.zkey> <file.wtns> [proof.json] [public.json]
prover --cpu <file.zkey> <file.wtns>
prover --metal <file.zkey> <file.wtns>
```

On macOS the default is CPU and Metal together. `--cpu` is the pure Zig prover.

## zkey in place of snarkjs

| snarkjs | zkey |
|---|---|
| `snarkjs groth16 setup a.r1cs ceremony.ptau out_0000.zkey` | `zkey setup a.r1cs ceremony.ptau out_0000.zkey` |
| `snarkjs zkey contribute in.zkey out.zkey --name="name"` | `zkey contribute in.zkey out.zkey "name"` |
| `snarkjs zkey export verificationkey out.zkey vk.json` | `zkey vk out.zkey vk.json` |

Setup and contribute in one step, key held in memory and written once:

```sh
zkey a.r1cs ceremony.ptau out_0001.zkey vk.json "1st Contributor Name"
```

The verification key uses the same JSON snarkjs writes: one-space indent and no trailing newline. Contribution entropy comes from the operating system, so a new contribution hash differs on every run.

Check a key by proving and verifying through the shared library:

```sh
zkey prove "$(zkey lib)" out_0001.zkey witness.wtns vk.json
```

## Speed

Blackjack showdown key (`blackjack_showdown_hashout_main`, about 661k signals, domain 2^20). Setup and contribute together:

| | wall time | vs snarkjs |
|---|---:|---:|
| snarkjs | 340.69 s | |
| zkey, CPU + Metal | 31.32 s | 10.9× |

snarkjs on that key was 250.53 s of setup and 90.16 s of contribute.

Prove, witness from libzkcasino, `r = s = 0`, verified with snarkjs. Wall time is the second run.

| Circuit | CPU + Metal | rapidsnark | speedup |
|---|---:|---:|---:|
| Blackjack showdown (661,104 signals) | 1.75 s | 3.28 s | 1.9× |
| Poker showdown (2,244,633 signals) | 6.58 s | 10.02 s | 1.5× |

Proofs with `r = s = 0` verify and are a different byte string from a rapidsnark proof, which draws its own `r` and `s`.

Sections 1–9 of the blackjack proving key match snarkjs. Section 10’s circuit hash differs: the last `hashH` read in a Hermez powers-of-tau file extends past the end of that section. Smaller keys, including a coefficient-5 circuit proved with the Metal and CPU split, match snarkjs byte for byte. The exported verification key matches snarkjs byte for byte.

## What makes it faster

**zkey.** Coefficients are count-sorted by signal. Each thread owns a range of signals and folds that signal’s touches into one Jacobian that stays in registers. Scalar multiplies use GLV. Metal takes the G1 scalar multiplies; the CPU threads take the G2 suffix, because ten cores beat the GPU on G2 and the GPU is already busy with G1. Field multiply and square are inlined on the CPU. The Metal field kernels stay outlined: inlining them made the GPU slower. The whole key stays in memory and is written once after contribute.

**Prove.** One 64k-point chunk of the G2 multiscalar multiply runs on Zig threads while Metal runs the G1 multiscalar multiplies (A, B1, C). Metal then takes the rest of G2 on the main thread. The two ranges do not overlap. The QAP runs on a Zig thread during the G1 work. `H = A·B − C` (inverse FFT, coset shift, FFT, pointwise product) stays on the GPU, and only `h` is copied back. G1 coordinates are written straight into Metal buffers. FFT buffers are allocated once, for a domain of 2^22.

A few things were measured and left out because they were slower: more than one G2 chunk on the CPU, a parallel QAP, and allocating every scratch buffer before the prove.
