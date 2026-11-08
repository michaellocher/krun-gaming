// Guest test (arm64): does hardware TSO (Apple's ACTLR bit, set through the Asahi PR_SET_MEM_MODEL prctl that FEX
// uses) take effect inside the VM? Message-passing litmus: writer stores data then flag, reader loads flag then
// data with plain (relaxed) accesses. Weak ARM ordering allows flag=1,data=0; TSO forbids it.
// Usage: tso-litmus [tso] [iterations]. Build (builder VM): gcc -O2 -pthread -o tso-litmus tso-litmus.c
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>

#define PR_GET_MEM_MODEL 0x6d4d444c
#define PR_SET_MEM_MODEL 0x4d4d444c
#define PR_SET_MEM_MODEL_TSO 1

static volatile long data, flag;
static long iters;
static int tso;
static atomic_int stop;

static void set_tso(int on) {
    if (on && prctl(PR_SET_MEM_MODEL, PR_SET_MEM_MODEL_TSO, 0, 0, 0) != 0) {
        perror("prctl PR_SET_MEM_MODEL");
        exit(2);
    }
}

// writer: data = i, then flag = i (TSO keeps that order for every observer)
static void *writer(void *arg) {
    (void)arg;
    set_tso(tso);
    for (long i = 1; i <= iters; i++) {
        data = i;
        flag = i;
    }
    atomic_store(&stop, 1);
    return NULL;
}

static long forbidden, samples;

// reader: flag, then data; seeing data older than flag is impossible under TSO
static void *reader(void *arg) {
    (void)arg;
    set_tso(tso);
    while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
        long f = flag;
        long d = data;
        forbidden += d < f;
        samples++;
    }
    return NULL;
}

int main(int argc, char **argv) {
    tso = argc > 1 && !strcmp(argv[1], "tso");
    iters = argc > 2 ? atol(argv[2]) : 200000000;
    set_tso(tso);
    printf("mem model: %d\n", prctl(PR_GET_MEM_MODEL, 0, 0, 0, 0));
    pthread_t w, r;
    pthread_create(&r, NULL, reader, NULL);
    pthread_create(&w, NULL, writer, NULL);
    pthread_join(w, NULL);
    pthread_join(r, NULL);
    printf("%s: %ld of %ld reads saw data older than flag (forbidden under TSO)\n", tso ? "TSO requested" : "default",
           forbidden, samples);
    return 0;
}
