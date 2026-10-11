template Benchmark_1000() {
    signal input in;
    signal output out;

    signal intermediate[1000];
    intermediate[0] <== in + 1;

    for (var i = 1; i < 1000; i++) {
        intermediate[i] <== intermediate[i - 1] + 1;
    }

    out <== intermediate[1000 - 1];
}

component main = Benchmark_1000();
