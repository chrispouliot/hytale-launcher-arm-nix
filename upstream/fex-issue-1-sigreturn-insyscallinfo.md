# Guest signal frames built from stale state after a normal `rt_sigreturn` (`InSyscallInfo` not restored)

**Version:** FEX-2608 (also present on `main` as of 2026-09-02)
**Host:** aarch64, Snapdragon X2 Elite (Oryon-3), NixOS, 4K pages
**Guest:** x86-64 .NET NativeAOT application (Hytale client); Go binaries show the same issue with async preemption signals

## Summary

After a guest signal handler returns normally (no RIP change), `Frame->InSyscallInfo` is left holding the marker written by the guest's `rt_sigreturn` syscall. The next asynchronous signal that lands in JIT code on that thread then skips spilling the masked host registers in `SpillSRA`, so the guest signal frame is built from `Frame->State` — which at that point is the state restored at the previous sigreturn, i.e. the thread's state one call level up. The frame is written over live stack data of the thread.

Any application that takes asynchronous signals while executing JIT code is affected as soon as it takes a second signal on the same thread: .NET's GC suspension (`SIGRTMIN` activation signal), Go's async preemption, profiling timers.

## Mechanism

1. The guest handler returns via `rt_sigreturn`. That is a guest syscall executed through `DEF_OP(Syscall)`, which spills the SRA, stores `InSyscallInfo = GPRSpillMask & 0xFFFF` and calls the handler.
2. `HandleSigreturn` → `RestoreThreadState` → `RestoreFrame_x64` restores the host context saved at delivery and resumes at the original delivery point in JIT code. The syscall op's epilogue (`str zr, [STATE, InSyscallInfo]`) never runs.
3. `RestoreFrame_x64` restores `Frame->InSyscallInfo = Context->InSyscallInfo` only inside the "guest modified the RIP" branch (`GuestFramesManagement.cpp` lines 125–134 in 2608; same for the two ia32 variants at 213/292). In the normal branch the stale marker survives.
4. The next signal in JIT code: `HandleDispatcherGuestSignal` sees `WasInJIT` and `Frame->InSyscallInfo != 0`, passes `IgnoreMask = InSyscallInfo & 0xFFFF` to `SpillSRA`, which skips every SRA register whose host index is < 16 — RSP included. `NewGuestSP` is derived from the stale `State.gregs[REG_RSP]`.

## Steps to reproduce

Attached: `fex-sigframe-repro.c` — a worker thread alternates between a shallow busy loop and a 12-deep call chain whose frames hold a known pattern, while the main thread sends it `SIGUSR1` every 20 µs; the handler just returns. No sigaltstack, `SA_SIGINFO | SA_RESTART`.

```
# build a static x86-64 binary (no RootFS needed); any static libc works, e.g. musl:
gcc -O1 -pthread -static -o fex-sigframe-repro fex-sigframe-repro.c

# run under FEX on the aarch64 host
FEXInterpreter ./fex-sigframe-repro
```

Expected (native x86-64, and FEX with the fix below):

```
OK: 299914 signals delivered, no frame corruption
```

Actual (FEX-2608, Snapdragon X2 Elite, static musl build of the reproducer):

```
FRAME CORRUPTED: depth 3 word 9 = 0x4019c7 (expected 0x5a5a000300000009), 4 signals so far
  frame at 0x7ffff7efd540; a guest signal frame was written over live stack data
```

The value that replaced the pattern, `0x4019c7`, is a guest code address — the `RIP` field of the `ucontext` in the misplaced signal frame. It fails on the 4th signal, i.e. the first one delivered in the deep phase after a return from the shallow phase.

With the fix below, same binary, same machine:

```
OK: 299995 signals delivered, no frame corruption
```

The original finding was a .NET NativeAOT game that died within a minute of heavy GC activity with several unrelated-looking signatures (stack-protector aborts, `SetupFrame_x64` faulting with `NewGuestSP = 0xfffffffffffffbb0` because `State.gregs[RSP]` was still 0 for a running thread, GC heap corruption); the reproducer isolates the mechanism.

## Observed in the original application

- Stack-protector aborts in a native function that cannot write its own frame (sentry-native's ELF reader). Dumping the frame at `__stack_chk_fail` showed the canary slot zeroed and, above it, FEX's xstate magic and the `ContextBackup` host pointer written by `SetupFrame_x64` — a guest signal frame, placed ~0x150 bytes above the thread's real RSP (one call level up).
- A core where `SetupFrame_x64` itself faulted with `NewGuestSP = 0xfffffffffffffbb0`: `State.gregs[RSP] == 0` for a running thread (state never written since thread creation, never spilled because of the stale marker).
- Heap/GC corruption in the guest (frames written over a thread's locals that hold GC roots).

With `FEX_MAXINST=1` the problem is invisible in the game (the state is written back at every instruction boundary), which is how it was narrowed down.

## Fix

Restore `InSyscallInfo` unconditionally on every sigreturn path. The saved value is the one current at delivery: `0` for a signal that landed in JIT code, or the syscall's own mask if it landed during a syscall — in which case execution resumes in that syscall op's post-call code, whose epilogue clears it.

```diff
--- a/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
+++ b/Source/Tools/LinuxEmulation/LinuxSyscalls/SignalDelegator/GuestFramesManagement.cpp
@@ -127,12 +127,17 @@
   auto* guest_uctx = reinterpret_cast<FEXCore::x86_64::ucontext_t*>(Context->UContextLocation);
   [[maybe_unused]] auto* guest_siginfo = reinterpret_cast<siginfo_t*>(Context->SigInfoLocation);
 
+  // Restore the InSyscallInfo that was current when the signal was delivered.
+  // Unconditionally: the guest's rt_sigreturn is itself a syscall op that set
+  // the marker, and returning straight to the delivery context skips its
+  // clearing epilogue. Leaving it set makes the next signal that lands in JIT
+  // code skip spilling the live registers (including RSP) and build its frame
+  // from stale state one call level up -- on top of live stack data.
+  Frame->InSyscallInfo = Context->InSyscallInfo;
+
   // If the guest modified the RIP then we need to take special precautions here
   if (Context->OriginalRIP != guest_uctx->uc_mcontext.gregs[FEXCore::x86_64::FEX_REG_RIP] || Context->FaultToTopAndGeneratedException) {
 
-    // Restore previous `InSyscallInfo` structure.
-    Frame->InSyscallInfo = Context->InSyscallInfo;
-
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
@@ -208,11 +213,16 @@
 void SignalDelegator::RestoreFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                         FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   SigFrame_i32* guest_uctx = reinterpret_cast<SigFrame_i32*>(Context->UContextLocation);
+  // Restore the InSyscallInfo that was current when the signal was delivered.
+  // Unconditionally: the guest's rt_sigreturn is itself a syscall op that set
+  // the marker, and returning straight to the delivery context skips its
+  // clearing epilogue. Leaving it set makes the next signal that lands in JIT
+  // code skip spilling the live registers (including RSP) and build its frame
+  // from stale state one call level up -- on top of live stack data.
+  Frame->InSyscallInfo = Context->InSyscallInfo;
+
   // If the guest modified the RIP then we need to take special precautions here
   if (Context->OriginalRIP != guest_uctx->sc.ip || Context->FaultToTopAndGeneratedException) {
-    // Restore previous `InSyscallInfo` structure.
-    Frame->InSyscallInfo = Context->InSyscallInfo;
-
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
@@ -286,12 +296,17 @@
 void SignalDelegator::RestoreRTFrame_ia32(FEXCore::Core::InternalThreadState* Thread, ArchHelpers::Context::ContextBackup* Context,
                                           FEXCore::Core::CpuStateFrame* Frame, void* ucontext) {
   RTSigFrame_i32* guest_uctx = reinterpret_cast<RTSigFrame_i32*>(Context->UContextLocation);
+  // Restore the InSyscallInfo that was current when the signal was delivered.
+  // Unconditionally: the guest's rt_sigreturn is itself a syscall op that set
+  // the marker, and returning straight to the delivery context skips its
+  // clearing epilogue. Leaving it set makes the next signal that lands in JIT
+  // code skip spilling the live registers (including RSP) and build its frame
+  // from stale state one call level up -- on top of live stack data.
+  Frame->InSyscallInfo = Context->InSyscallInfo;
+
   // If the guest modified the RIP then we need to take special precautions here
   if (Context->OriginalRIP != guest_uctx->uc.uc_mcontext.gregs[FEXCore::x86::FEX_REG_EIP] || Context->FaultToTopAndGeneratedException) {
 
-    // Restore previous `InSyscallInfo` structure.
-    Frame->InSyscallInfo = Context->InSyscallInfo;
-
     // Hack! Go back to the top of the dispatcher top
     // This is only safe inside the JIT rather than anything outside of it
     ArchHelpers::Context::SetPc(ucontext, Config.AbsoluteLoopTopAddressFillSRA);
```

With this applied, the NativeAOT game that previously died within a minute of world load (every run, several distinct crash signatures) runs stably.

## Related (separate reports to follow)

- `DEF_OP(Thunk)`, `CPUID`, `XGetBV`, `ThreadRemoveCodeEntry`, `MonoBackpatcherWrite` spill the SRA around host calls without setting the marker, so a signal landing after the host call returns "spills" the callee's leftover host registers over the correct state; `SpillSRA` also overwrites FPRs/flags regardless of the mask.
- FEX's own SIGSEGV/SIGBUS/SIGILL host handlers run with async signals unmasked; a signal nesting inside the unaligned-access backpatcher is deferred and delivered from host context.
