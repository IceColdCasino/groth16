#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <assert.h>

// rapidsnark C API
extern int groth16_prover_zkey_file(
    const char* zkey_fname,
    const void* wtns_buffer,
    unsigned long long wtns_size,
    char* proof_buffer,
    unsigned long long* proof_size,
    char* public_buffer,
    unsigned long long* public_size,
    char* error_msg,
    unsigned long long error_msg_maxsize
);

extern int groth16_prover(
    const void* zkey_buffer,
    unsigned long long zkey_size,
    const void* wtns_buffer,
    unsigned long long wtns_size,
    char* proof_buffer,
    unsigned long long* proof_size,
    char* public_buffer,
    unsigned long long* public_size,
    char* error_msg,
    unsigned long long error_msg_maxsize
);

static unsigned char* read_file(const char* path, size_t* out_size) {
    FILE* f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    size_t size = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char* buf = (unsigned char*)malloc(size);
    fread(buf, 1, size, f);
    fclose(f);
    *out_size = size;
    return buf;
}

int main(int argc, char** argv) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <zkey> <witness>\n", argv[0]);
        return 1;
    }

    const char* zkey_path = argv[1];
    const char* wtns_path = argv[2];

    size_t wtns_size = 0;
    unsigned char* wtns_buf = read_file(wtns_path, &wtns_size);
    assert(wtns_buf);

    char proof_buf[65536];
    unsigned long long proof_size = sizeof(proof_buf);
    char public_buf[65536];
    unsigned long long public_size = sizeof(public_buf);
    char error_msg[1024];

    printf("Testing groth16_prover_zkey_file...\n");
    int rc = groth16_prover_zkey_file(
        zkey_path,
        wtns_buf, wtns_size,
        proof_buf, &proof_size,
        public_buf, &public_size,
        error_msg, sizeof(error_msg)
    );
    if (rc != 0) {
        fprintf(stderr, "groth16_prover_zkey_file failed: %d, %s\n", rc, error_msg);
        free(wtns_buf);
        return 1;
    }
    printf("  proof_size=%llu, public_size=%llu\n", proof_size, public_size);
    printf("  proof: %.*s\n", (int)proof_size, proof_buf);
    printf("  public: %.*s\n", (int)public_size, public_buf);

    size_t zkey_size = 0;
    unsigned char* zkey_buf = read_file(zkey_path, &zkey_size);
    assert(zkey_buf);

    proof_size = sizeof(proof_buf);
    public_size = sizeof(public_buf);

    printf("\nTesting groth16_prover (memory-based)...\n");
    rc = groth16_prover(
        zkey_buf, zkey_size,
        wtns_buf, wtns_size,
        proof_buf, &proof_size,
        public_buf, &public_size,
        error_msg, sizeof(error_msg)
    );
    if (rc != 0) {
        fprintf(stderr, "groth16_prover failed: %d, %s\n", rc, error_msg);
        free(wtns_buf);
        free(zkey_buf);
        return 1;
    }
    printf("  proof_size=%llu, public_size=%llu\n", proof_size, public_size);
    printf("  proof: %.*s\n", (int)proof_size, proof_buf);
    printf("  public: %.*s\n", (int)public_size, public_buf);

    free(wtns_buf);
    free(zkey_buf);

    printf("\nAll FFI tests passed!\n");
    return 0;
}
