# Hytale Launcher for ARM Linux/NixOS

Hytale on **aarch64 NixOS**. Tested on an ASUS Zenbook A14 (Snapdragon X2 Elite,
Adreno X2‑90, Mesa 26.2). It plays!

- **Launcher** (Go/Wails, x86_64): runs under the same **patched FEX**, with its
  own FEX config directory and FEXServer.
- **Client** (.NET 10 NativeAOT, x86_64): runs under a **patched FEX** with a
  nixpkgs x86_64 userland and FEX's GL thunk (native Adreno driver).
- **Server** (Java): runs **natively** (Temurin 25, aarch64) - the jar's
  `linux-x64` natives are replaced by aarch64 builds (quiche 0.29.3 with the
  Hypixel‑fork additions, RocksDB, zstd, Netty QUIC, JLine).

Nothing in the Hytale install is modified. The launcher zip is fetched from
Hytale's CDN at build time; the game itself is downloaded by the launcher as
usual. You need a Hytale account like anyone else.

## Usage

```nix
{
  inputs.hytale-arm.url = "github:chrispouliot/hytale-launcher-arm-nix";
  # optional: reuse a nixpkgs you already track (must ship fex 2608)
  # inputs.hytale-arm.inputs.nixpkgs-fex.follows = "nixpkgs-unstable";

  outputs = { nixpkgs, hytale-arm, ... }: {
    nixosConfigurations.laptop = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      modules = [
        hytale-arm.nixosModules.default
        { programs.hytale.enable = true; }
      ];
    };
  };
}
```

### Pinning

Two things are pinned, differently:

- **FEX source**: the module fetches the `FEX-2608` tag itself (same source
  block and hash as nixpkgs' `fex` package) and applies the eight patches to
  it. A nixpkgs that ships a newer FEX changes nothing here.
- **nixpkgs (`nixpkgs-fex`)**: provides the FEX build recipe and the x86_64
  guest userland. The committed `flake.lock` holds a revision that is known to
  build; it only moves when you run `nix flake update`. If you want it fixed
  regardless of lock files, set the input URL to a revision (see the comment
  in `flake.nix`). The revision your own system already uses is in your
  `flake.lock`: `jq -r '.nodes["nixpkgs-fex"].locked.rev' flake.lock`.

The build recipe drifting far from 2608 is the residual risk (e.g. a cmake flag
2608 does not know); that would fail at build time, not at run time.

`programs.hytale.enable` also turns on `programs.fex` - the FEX‑x86_64/FEX‑x86
binfmt registrations - because the launcher starts the client and the server
through the kernel's binfmt shim, and the shim's hook is what puts the client
on its emulator setup and swaps in the native server JRE.

Hytale is siloed: its whole process tree runs on the patched FEX‑2608 with its
own config directory and FEXServer. Everything else (Steam…) reaches the
shim's default interpreter, `programs.fex.package`, which is **stock nixpkgs
FEX** - newer, stripped, and not carrying patches validated on one game. To
run other programs on the patched build anyway:
`programs.fex.package = config.programs.hytale.fexPackage;`.

`nixos-rebuild switch` builds FEX (with patches), an aarch64 quiche and
the Java server wrapper - the first build takes a while. The x86_64 client
userland (glibc, X11, audio, codecs…) is plain nixpkgs `x86_64-linux` and comes
from cache.nixos.org; if something in it ever needs building locally, add
`nix.settings.extra-platforms = [ "x86_64-linux" ]` (the FEX binfmt makes that
work). Afterwards: `hytale`, or the *Hytale* desktop entry.

### Options

| Option | Default | Meaning |
|---|---|---|
| `programs.fex.enable` | `false` (`true` with Hytale) | FEX‑x86_64 / FEX‑x86 binfmt registrations through a hook‑capable shim. Do not combine with `boot.binfmt.emulatedSystems = [ "x86_64-linux" ]` (it registers the wrong name). |
| `programs.fex.package` | nixpkgs `fex` | The FEX used by the shim's default path and as `FEXInterpreter` (programs outside Hytale). |
| `programs.hytale.fexPackage` | read‑only | The patched FEX‑2608 build Hytale runs on; assign it to `programs.fex.package` to opt other programs in. |
| `programs.fex.rootfs` | `null` | Global RootFS (e.g. FEX's Ubuntu image) for *other* x86 programs such as Steam; written to `~/.fex-emu/Config.json` for `programs.fex.users`. Hytale does not use it. |
| `programs.fex.users` | `[ ]` | Users that get that config file. |
| `programs.fex.binBash` | `false` | Symlink `/bin/bash` (Steam's scripts assume it). |
| `programs.hytale.enable` | `false` | Everything Hytale. |
| `programs.hytale.environment` | `{ }` | Runtime knobs (table below) exported by the `hytale` wrapper, so they also apply to the desktop entry. |
| `programs.hytale.coredumps` | `false` | Raise systemd‑coredump caps so FEX dumps are complete (debugging only). |

### Runtime knobs (environment variables, all optional)

Set them per run in the shell (`HYTALE_FEX_STACKCHK=1 hytale`) or
declaratively:

```nix
programs.hytale.environment = {
  DOTNET_GCgen0size = "0x40000000";
};
```

Every consumer uses `${VAR:-default}`, so a variable set in the launching
shell overrides both the declared value and the built‑in default.

| Variable | Default | Effect |
|---|---|---|
| `DOTNET_gcConservative` | `1` | Required under FEX: conservative GC stack scanning, no context edits from the suspension signal. |
| `DOTNET_GCgen0size` | `0x20000000` | 512 MB gen0 budget: fewer stop‑the‑world GCs (each one signals every thread, which is expensive under emulation). |
| `FEX_HALFBARRIERTSOALWAYS` | `0` | `1`: emit every scalar TSO access as `ldur/stur + dmb` up front instead of letting FEX backpatch on SIGBUS. Slower; useful to isolate backpatcher problems. |
| `HYTALE_FEX_VIDEO` | `x11` | `wayland` for SDL3's Wayland backend (untested beyond "no window"). |
| `HYTALE_FEX_THUNKS` | `1` | `0`: no GL thunk, emulated x86 Mesa/llvmpipe (software rendering, diagnostic). |
| `HYTALE_FEX_STACKCHK` | `0` | `1`: preload a guest‑side diagnostic shim: guest SIGSEGV/SIGBUS reporter, `__stack_chk_fail` frame dump, periodic guest object/maps recorder. |
| `HYTALE_FEX_NOMODSCAN` | unset | `1`: starve sentry‑native's module scan (denies `/proc/self/maps` after startup). |
| `HYTALE_FEX_NOVMREAD` | unset | `1`: make sentry‑native's memory reader use `memcpy` instead of `process_vm_readv`. |

### Logs

- `~/.cache/hytale/fex-client.log` - FEX/client stderr of the last run
- `~/.local/share/Hytale/UserData/Logs/*_client.log` - the client's own log
- `~/.cache/hytale/guest-objects.txt` - guest loader view, only with `HYTALE_FEX_STACKCHK=1`
- `coredumpctl list` - with `programs.hytale.coredumps = true` and `ulimit -c unlimited`, FEX dumps are complete and symbolised (`RelWithDebInfo`, not stripped)

## Status

- **Client: playable.** Menu, singleplayer world load, gameplay, audio.
- **Server:** the whole chain works natively (QUIC listener, mutual TLS,
  RocksDB, asset streaming).
- Launcher, client and their FEXServer run the patched build; the binfmt
  default for other programs stays stock.
- Not tried: the Wayland video path (no window so far); a Vulkan renderer, if
  the client has one.
- box64 was the first attempt and was dropped: it reconstructs the guest
  context for asynchronous signals at the containing x86 instruction, not
  instruction‑precise, which NativeAOT's GC suspension cannot tolerate, so it
  never got past world entry. Three real box64 bugs found on the way are in
  `upstream/box64/`.

## What is patched, and why

Everything here was found by debugging this game; the emulator patches are
general bugs, not Hytale‑specific hacks.

### FEX (`patches/fex`, against FEX‑2608)

| Patch | Kind | What |
|---|---|---|
| `fex-sigreturn-insyscall` | **bug** | `RestoreFrame_*` restored `InSyscallInfo` only when the guest changed RIP. After a normal `rt_sigreturn` the marker written by the sigreturn syscall op survived, so the next signal landing in JIT code skipped spilling the live registers (RSP included) and built its frame from stale state one call level up - over live stack data. The root cause of nearly everything; reproducer and report in `upstream/`. |
| `fex-hostcall-window` | bug | JIT ops that call host code (`Thunk`, `CPUID`, `XGetBV`, `ThreadRemoveCodeEntry`, `MonoBackpatcherWrite`) spilled the guest state but never told the signal handler; a signal after the host call returned "spilled" the callee's leftover host registers over it. `SpillSRA` also always overwrote FPRs/flags. |
| `fex-required-handlers-mask` | bug | FEX's own SIGSEGV/SIGBUS/SIGILL host handlers ran with async signals unmasked; a signal nesting inside the unaligned‑access backpatcher (constant on the X2 Elite's 16‑byte fault granularity) was deferred and delivered from host context. |
| `fex-torn-fastpath` | bug | The `ret`/L1 fast paths `ldp` a (guest RIP, host address) pair and only compare the RIP half; another thread clearing the entry (L1 word‑wise, call‑ret stack via `madvise`) gives a matching RIP with a zero host address → `ret` to 0. |
| `fex-live-codebuffers-signal` | bug | `IsAddressInCodeBuffer` only knew the thread's current code buffer; older versioned buffers stay executable, so signals landing there were classified "not in JIT". |
| `fex-gl-thunk-texstorage-ext` | bug | GL thunk lacked `GL_EXT_texture_storage` (`glTexStorage{1,2,3}DEXT`) although Mesa advertises it → `glXGetProcAddress` returned NULL → call to 0. |
| `fex-abort-on-host-fault` | diagnostic | A synchronous fault in FEX's own host code was forwarded to the guest (which then resumed past the syscall with the host operation abandoned); abort instead so the core has the frames. |
| `fex-halfbarrier-tso-always` | option | `HalfBarrierTSOAlways`: emit the barrier form of scalar TSO accesses up front. Off by default. |

### Server side (in `modules/hytale.nix`)

- aarch64 **quiche 0.29.3** (crates.io, `ffi+qlog+sfv`) plus the three
  functions the Hypixel fork adds: `quiche_config_load_cert`,
  `quiche_config_load_priv_key` (PEM or DER), `quiche_config_verify_peer_optional`.
- nixpkgs RocksDB/zstd packed under the jar's `native/linux-x64/` names in an
  overlay jar; `--java-exec` wrapper rewrites `-jar` into `-cp overlay:jar Main`,
  spoofs `os.arch=amd64` for the loaders, pins `jdk.internal.foreign.CABI=LINUX_AARCH_64`,
  and extracts the aarch64 Netty QUIC / zstd‑jni / JLine natives into a
  per‑jar cache for `java.library.path`.

### Client startup

- Guest thunk libraries copied as regular files first on the guest
  `LD_LIBRARY_PATH` (FEX's RootFS symlink decoys aren't reachable from a
  nixpkgs `ld.so`), patched to declare `libstdc++`.

## Upstream

`upstream/` holds the FEX report for the sigreturn bug, the minimal diff
(applies to 2608 and current `main`), a self‑contained reproducer
(`fex-sigframe-repro.c`: fails on the 4th signal on FEX‑2608, 300k signals
clean with the fix), and the box64 patches. The other FEX patches and the SDL3
`SDL_GetGamepadMappings` size slip are worth reporting too.

## Layout

```
flake.nix           nixosModules.{default,fex}
modules/fex.nix     binfmt shim + registrations, FEX package, optional global RootFS
modules/hytale.nix  everything Hytale (large; the FEX override is at the top)
patches/fex/        FEX patches (see table)
upstream/           bug report, minimal patch, reproducer; box64 patches
```
