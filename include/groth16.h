#ifndef GROTH16_H
#define GROTH16_H

#ifdef __cplusplus
extern "C" {
#endif

#define PROVER_OK 0x0
#define PROVER_ERROR 0x1
#define PROVER_ERROR_SHORT_BUFFER 0x2
#define PROVER_INVALID_WITNESS_LENGTH 0x3

#define VERIFIER_VALID_PROOF 0x0
#define VERIFIER_INVALID_PROOF 0x1
#define VERIFIER_ERROR 0x2

int groth16_public_size_for_zkey_buf(
    const void *zkey_buffer,
    unsigned long long zkey_size,
    unsigned long long *public_size,
    char *error_msg,
    unsigned long long error_msg_maxsize);

int groth16_public_size_for_zkey_file(
    const char *zkey_fname,
    unsigned long long *public_size,
    char *error_msg,
    unsigned long long error_msg_maxsize);

void groth16_proof_size(unsigned long long *proof_size);

int groth16_prover_create(
    void **prover_object,
    const void *zkey_buffer,
    unsigned long long zkey_size,
    char *error_msg,
    unsigned long long error_msg_maxsize);

int groth16_prover_create_zkey_file(
    void **prover_object,
    const char *zkey_file_path,
    char *error_msg,
    unsigned long long error_msg_maxsize);

int groth16_prover_prove(
    void *prover_object,
    const void *wtns_buffer,
    unsigned long long wtns_size,
    char *proof_buffer,
    unsigned long long *proof_size,
    char *public_buffer,
    unsigned long long *public_size,
    char *error_msg,
    unsigned long long error_msg_maxsize);

void groth16_prover_destroy(void *prover_object);

int groth16_prover(
    const void *zkey_buffer,
    unsigned long long zkey_size,
    const void *wtns_buffer,
    unsigned long long wtns_size,
    char *proof_buffer,
    unsigned long long *proof_size,
    char *public_buffer,
    unsigned long long *public_size,
    char *error_msg,
    unsigned long long error_msg_maxsize);

int groth16_prover_zkey_file(
    const char *zkey_file_path,
    const void *wtns_buffer,
    unsigned long long wtns_size,
    char *proof_buffer,
    unsigned long long *proof_size,
    char *public_buffer,
    unsigned long long *public_size,
    char *error_msg,
    unsigned long long error_msg_maxsize);

/* proof, inputs, and verification_key are null-terminated JSON strings. */
int groth16_verify(
    const char *proof,
    const char *inputs,
    const char *verification_key,
    char *error_msg,
    unsigned long error_msg_maxsize);

#ifdef __cplusplus
}
#endif

#endif
