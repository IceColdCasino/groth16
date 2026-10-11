#!/usr/bin/env bash
set -euo pipefail

# generate_circuits.sh
# Generates benchmark circuits of varying sizes for the GPU prover.
# 
# NOTE: This script requires circom and snarkjs to be installed.
# Since these are not currently installed in this environment, this
# script serves as both documentation and a runnable generator.
#
# Prerequisites:
#   - Node.js 18+
#   - circom: cargo install circom
#   - snarkjs: npm install -g snarkjs
#
# Usage:
#   ./generate_circuits.sh [small|medium|large|xlarge|all]
#
# Output:
#   circuits/<size>/circuit_final.zkey
#   circuits/<size>/witness.wtns

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/circuits"

# Circuit sizes and their approximate constraint counts
# These Circom templates generate N constraints by chaining N additions
# in a simple arithmetic circuit.
SIZES=(
    "small:1000"
    "medium:100000"
    "large:1000000"
    "xlarge:10000000"
)

# Check prerequisites
check_prereqs() {
    if ! command -v circom &> /dev/null; then
        echo "ERROR: circom is not installed."
        echo "Install with: cargo install circom"
        echo "Or follow: https://github.com/iden3/circom"
        exit 1
    fi

    if ! command -v snarkjs &> /dev/null; then
        echo "ERROR: snarkjs is not installed."
        echo "Install with: npm install -g snarkjs"
        exit 1
    fi
}

# Generate a parameterized Circom template that creates N constraints
generate_circom_template() {
    local n_constraints=$1
    local output_file=$2

    cat > "$output_file" <<EOF
template Benchmark_${n_constraints}() {
    signal input in;
    signal output out;

    signal intermediate[${n_constraints}];
    intermediate[0] <== in + 1;

    for (var i = 1; i < ${n_constraints}; i++) {
        intermediate[i] <== intermediate[i - 1] + 1;
    }

    out <== intermediate[${n_constraints} - 1];
}

component main = Benchmark_${n_constraints}();
EOF
}

# Generate input.json for witness generation
generate_input() {
    local output_file=$1
    echo '{ "in": 1 }' > "$output_file"
}

# Full trusted setup + proving key generation for a single circuit
generate_circuit() {
    local size_name=$1
    local n_constraints=$2
    local build_dir="${OUTPUT_DIR}/${size_name}"

    echo "=== Generating ${size_name} circuit (${n_constraints} constraints) ==="
    mkdir -p "$build_dir"

    local circom_file="${build_dir}/benchmark.circom"
    local r1cs_file="${build_dir}/benchmark.r1cs"
    local wasm_file="${build_dir}/benchmark_js/benchmark.wasm"
    local input_file="${build_dir}/input.json"
    local witness_file="${build_dir}/witness.wtns"
    local zkey_file="${build_dir}/circuit_final.zkey"
    local pot_file="${build_dir}/pot.ptau"

    # 1. Generate Circom source
    generate_circom_template "$n_constraints" "$circom_file"

    # 2. Compile to R1CS + WASM
    echo "  Compiling Circom..."
    circom "$circom_file" --r1cs --wasm --sym -o "$build_dir"

    # 3. Generate input
    generate_input "$input_file"

    # 4. Compute witness
    echo "  Computing witness..."
    node "${build_dir}/benchmark_js/generate_witness.js" "$wasm_file" "$input_file" "$witness_file"

    # 5. Download or generate Powers of Tau
    # For production circuits use a downloaded, audited PTAU file.
    # For benchmarks we generate a local one (fast but not secure/trusted).
    local pot_size
    if [ "$n_constraints" -le 1000 ]; then
        pot_size=8
    elif [ "$n_constraints" -le 100000 ]; then
        pot_size=12
    elif [ "$n_constraints" -le 1000000 ]; then
        pot_size=16
    else
        pot_size=20
    fi

    echo "  Generating Powers of Tau (size ${pot_size})..."
    if [ ! -f "$pot_file" ]; then
        snarkjs powersoftau new bn128 "${pot_size}" "$pot_file" -v
    fi

    # 6. Phase 2: contribute to phase 2 for this circuit
    local p2_file="${build_dir}/circuit_0000.zkey"
    snarkjs groth16 setup "$r1cs_file" "$pot_file" "$p2_file"

    # 7. Finalize zkey (single contribution for benchmarking)
    local p2_contrib="${build_dir}/circuit_0001.zkey"
    snarkjs zkey contribute "$p2_file" "$p2_contrib" --name="benchmark" -v
    snarkjs zkey verify "$r1cs_file" "$pot_file" "$p2_contrib"
    snarkjs zkey beacon "$p2_contrib" "$zkey_file" 0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f 10 -n="Final"

    # 8. Verify final zkey
    snarkjs zkey verify "$r1cs_file" "$pot_file" "$zkey_file"

    # Cleanup intermediate files (keep only zkey and wtns)
    rm -rf "${build_dir}/benchmark_js"
    rm -f "$circom_file" "$r1cs_file" "$input_file" "$p2_file" "$p2_contrib" "$pot_file"
    if [ -f "${build_dir}/benchmark.sym" ]; then
        rm -f "${build_dir}/benchmark.sym"
    fi

    echo "  Done: ${zkey_file} + ${witness_file}"
}

# Main entrypoint
main() {
    local target="${1:-all}"

    check_prereqs
    mkdir -p "$OUTPUT_DIR"

    for size_spec in "${SIZES[@]}"; do
        local size_name="${size_spec%%:*}"
        local n_constraints="${size_spec##*:}"

        if [ "$target" = "all" ] || [ "$target" = "$size_name" ]; then
            generate_circuit "$size_name" "$n_constraints"
        fi
    done

    echo ""
    echo "All requested circuits generated in: ${OUTPUT_DIR}"
}

main "$@"
