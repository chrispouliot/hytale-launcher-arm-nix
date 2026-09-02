/* Reproducer: guest signal frames written from stale state after a normal
 * rt_sigreturn (FEX-2608, FEX main as of 2026-09-02).
 *
 * A worker thread alternates between a shallow busy loop and a deep call
 * chain whose frames hold a known pattern. The main thread keeps sending it
 * SIGUSR1; the handler does nothing and returns normally.
 *
 * Correct behaviour (native x86-64, or FEX with the fix): every signal frame
 * is placed below the interrupted frame's RSP, the pattern survives, the
 * program prints "OK".
 *
 * Buggy behaviour: after the first signal returns, Frame->InSyscallInfo keeps
 * the marker written by the rt_sigreturn syscall op. The next signal that
 * lands in JIT code skips spilling the live RSP and builds its frame from the
 * RSP of the previous delivery (shallow phase) -- on top of the deep phase's
 * live frames. The pattern check fails within a second or two.
 *
 * Build (x86-64):  gcc -O1 -pthread -o fex-sigframe-repro fex-sigframe-repro.c
 * Run:             FEXInterpreter ./fex-sigframe-repro   (or via binfmt)
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define DEPTH 12
#define WORDS 96 /* 768 bytes per frame; a signal frame is ~0x500 bytes */
#define PATTERN(d, i) (0x5a5a000000000000ULL ^ ((unsigned long long)(d) << 32) ^ (unsigned long long)(i))

static volatile sig_atomic_t signals_seen;
static volatile int stop;
static pthread_t worker;

static void handler(int sig, siginfo_t* si, void* uc) {
  (void)sig; (void)si; (void)uc;
  signals_seen++;
}

static void spin(unsigned long iters) {
  volatile unsigned long x = 0;
  for (unsigned long i = 0; i < iters; i++) x += i;
}

/* Deep phase: each level owns a pattern-filled buffer that it verifies after
 * the deeper levels (and a short spin) have run. noinline so every level is a
 * real frame. */
static __attribute__((noinline)) void deep(int d) {
  volatile unsigned long long buf[WORDS];
  for (int i = 0; i < WORDS; i++) buf[i] = PATTERN(d, i);

  if (d < DEPTH) {
    deep(d + 1);
  } else {
    spin(20000);
  }

  for (int i = 0; i < WORDS; i++) {
    if (buf[i] != PATTERN(d, i)) {
      fprintf(stderr,
              "FRAME CORRUPTED: depth %d word %d = %#llx (expected %#llx), %d signals so far\n"
              "  frame at %p; a guest signal frame was written over live stack data\n",
              d, i, buf[i], PATTERN(d, i), (int)signals_seen, (void*)buf);
      _exit(1);
    }
  }
}

static void* worker_main(void* arg) {
  (void)arg;
  while (!stop) {
    spin(20000); /* shallow phase: the "previous delivery" RSP is high */
    deep(1);     /* deep phase: live frames far below that RSP */
  }
  return NULL;
}

int main(void) {
  struct sigaction sa;
  memset(&sa, 0, sizeof sa);
  sa.sa_sigaction = handler;
  sa.sa_flags = SA_SIGINFO | SA_RESTART; /* no SA_ONSTACK: frames go on the thread stack */
  sigemptyset(&sa.sa_mask);
  if (sigaction(SIGUSR1, &sa, NULL) != 0) { perror("sigaction"); return 2; }

  if (pthread_create(&worker, NULL, worker_main, NULL) != 0) { perror("pthread_create"); return 2; }

  struct timespec ts = {0, 20000}; /* 20 us between signals */
  for (int i = 0; i < 300000; i++) {
    pthread_kill(worker, SIGUSR1);
    nanosleep(&ts, NULL);
  }
  stop = 1;
  pthread_join(worker, NULL);
  printf("OK: %d signals delivered, no frame corruption\n", (int)signals_seen);
  return 0;
}
