# Hytale on aarch64 NixOS: x86_64 launcher + client under a patched FEX,
# native aarch64 Java server. See ../README.md for the knobs.
{ inputs, config, pkgs, lib, ... }:

let
  # Same import as fex.nix -> identical store path -> the binfmt shim, the
  # launcher and the FEXServer all run the same FEX build.
  fexPkgs = import inputs.nixpkgs-fex { system = pkgs.stdenv.hostPlatform.system; };
  # FEX 2608 + one JIT option (HalfBarrierTSOAlways, env FEX_HALFBARRIERTSOALWAYS):
  # emit scalar TSO loads/stores directly as plain ldur/stur + DMB -- the form
  # FEX's SIGBUS handler otherwise backpatches in after an unaligned
  # acquire/release access faults. On the Snapdragon X2 Elite (16-byte fault
  # granularity) that fault-and-live-patch path fires constantly and left
  # threads of the NativeAOT client with corrupted state (false stack-canary
  # aborts, GC heap damage). Same instructions the backpatcher produces, same
  # footprint, no live code modification, TSO semantics preserved.
  fex = fexPkgs.fex.overrideAttrs (old: {
    # Pin the source the patches are written against, independently of the
    # FEX version nixpkgs ships: same src block as nixpkgs' fex 2608 (the
    # partial submodule init in postFetch is part of the hash).
    version = "2608";
    src = pkgs.fetchFromGitHub {
      owner = "FEX-Emu";
      repo = "FEX";
      tag = "FEX-2608";
      hash = "sha256-2NdkQpzqDkM/fEW8QYS05KU3JPJeLw4gliryqdOJ3vE=";
      leaveDotGit = true;
      postFetch = ''
        cd $out
        git reset

        # Only fetch required submodules
        git submodule update --init --depth 1 \
          External/Vulkan-Headers \
          External/drm-headers \
          External/rpmalloc \
          External/jemalloc_glibc \
          External/vixl \
          External/unordered_dense \
          Source/Common/cpp-optparse

        find . -name .git -print0 | xargs -0 rm -rf

        # Remove some more unnecessary directories
        rm -r \
          External/vixl/src/aarch32 \
          External/vixl/test
      '';
    };
    # Keep symbols so a FEX host crash can be read from the coredump.
    cmakeBuildType = "RelWithDebInfo";
    dontStrip = true;
    patches = (old.patches or []) ++ [
      ../patches/fex/fex-halfbarrier-tso-always.patch
      # The GL thunk's glXGetProcAddress table lacked GL_EXT_texture_storage,
      # which Mesa advertises: the client trusts the extension string, gets
      # NULL for glTexStorage2DEXT and jumps to 0 at the first texture upload.
      ../patches/fex/fex-gl-thunk-texstorage-ext.patch
      # ROOT CAUSE of the FEX-side corruption: FEX-2608's shared code buffers
      # are versioned -- old buffers stay executable for threads that have not
      # moved to the latest one -- but SignalDelegator classifies "signal landed
      # in JIT code" with IsAddressInCodeBuffer(), which only knows the
      # receiving thread's *current* buffer. A signal landing in an older
      # buffer is treated as "not in JIT": the host registers are not spilled
      # and the guest signal frame is built from a stale RSP, i.e. written
      # over live stack data (stack-canary aborts in sentry-native, a corrupt
      # on-stack FILE in sscanf, RSP=0 frames -> FEX SIGSEGV in SetupFrame_x64,
      # GC root damage). Fix: a lock-free registry of all live CodeBuffer
      # ranges, consulted from the signal path.
      ../patches/fex/fex-live-codebuffers-signal.patch
      # Second half of the same bug: FEX's own SIGBUS/SIGSEGV/SIGILL host
      # handlers ran with async signals unmasked, so the GC's SIGRTMIN could
      # nest inside the unaligned-access backpatcher (constant on the X2 Elite
      # with its 16-byte fault granularity), get deferred, and be delivered
      # from host context with the JIT registers never spilled. Block async
      # signals for the duration of those handlers.
      ../patches/fex/fex-required-handlers-mask.patch
      # The actual stale-state bug: JIT ops that call out to host code (Thunk --
      # vDSO clock_gettime and every GL call --, CPUID, XGetBV,
      # ThreadRemoveCodeEntry, MonoBackpatcherWrite) spill the guest registers
      # to State, call, then refill; only Syscall told the signal handler about
      # it (InSyscallInfo, GPRs only). A signal landing after the host call
      # returned had its context "spilled" from the callee's leftover host
      # registers (RSP = 0 was one such leftover), and FPRs/flags were always
      # overwritten. All host-call windows now mark the state as fully spilled
      # (InSyscallInfo bit 31) and SpillSRA honours it.
      ../patches/fex/fex-hostcall-window.patch
      # Diagnostic: a synchronous fault in FEX's own host code used to be
      # delivered to the guest (which then resumed past the syscall with the
      # host operation abandoned). Abort instead so the core shows the frames.
      ../patches/fex/fex-abort-on-host-fault.patch
      # Torn fast-path read: the JIT's ret/L1 fast paths ldp a (guest RIP,
      # host address) pair and only compare the RIP half before ret/br to the
      # host half, while other threads clear those entries (L1 word by word,
      # the call-ret stack via madvise DONTNEED, which FEX's own comment calls
      # non-atomic). A torn read = still-matching RIP + zeroed host address
      # = ret to 0 (the host PC 0 core, LR = the guest call's bl). Require a
      # non-zero host address before taking either fast path.
      ../patches/fex/fex-torn-fastpath.patch
      # THE root cause of the stale-RSP signal frames: RestoreFrame_* restores
      # Frame->InSyscallInfo only in the "guest modified RIP" branch. The
      # guest's rt_sigreturn is itself a JIT syscall op that set the marker,
      # and the normal return jumps straight back to the delivery context, so
      # its clearing epilogue never runs: the marker stays set, the next signal
      # that lands in JIT code skips spilling the live registers (RSP among
      # them) and builds its frame from the state of the previous delivery, one
      # call level up, over live stack data (sentry's canary, sscanf's FILE,
      # GC roots; Go's preemption signals hit the same thing). Restore it
      # unconditionally. Also let the SMC fault path honour the bit-31 marker.
      ../patches/fex/fex-sigreturn-insyscall.patch
    ];
  });
  java = pkgs.temurin-jre-bin-25;  # native aarch64; the official bundle is Temurin 25

  # HytaleServer.jar ships its natives for linux-x64 only (native/linux-x64/
  # {libquiche,librocksdb,libzstd}.so) and its loaders throw "Unsupported
  # Linux architecture: aarch64", so the singleplayer server comes up with no
  # QUIC listener. Fix without touching the install: an overlay jar carrying
  # aarch64 builds at the *same* resource paths goes first on the classpath
  # (classpath order wins for resources) and -Dos.arch=amd64 makes the
  # loaders take the linux-x64 branch. Versions match the bundle: quiche
  # 0.29.3 (C API), RocksDB 10.x (C API), zstd 1.5.7.
  quiche = pkgs.rustPlatform.buildRustPackage rec {
    pname = "quiche";
    version = "0.29.3";
    src = pkgs.fetchCrate {
      inherit pname version;
      hash = "sha256-xADGDJzb3NQPY6AS3KZq/D9jglDRAQofUpnxYKV8zZM=";
    };
    cargoLock.lockFile = "${src}/Cargo.lock";   # crates.io package ships one, no git deps
    nativeBuildInputs = [ pkgs.cmake pkgs.perl pkgs.git pkgs.rustPlatform.bindgenHook ];  # boring-sys: cmake for BoringSSL, git init for its patch step
    dontUseCmakeConfigure = true;
    # Hytale's QuicheNative resolves every symbol eagerly. Beyond upstream's
    # ffi it needs qlog (quiche_conn_set_qlog_*), sfv
    # (quiche_h3_parse_extensible_priority) and three fork-only functions --
    # in-memory cert/key loading and optional peer verification -- which are
    # appended below (signatures recovered from the Java FunctionDescriptors).
    buildFeatures = [ "ffi" "qlog" "sfv" ];
    postPatch = ''
      cat ${pkgs.writeText "hytale-quiche-tls.rs" ''

      // ---- Hytale-fork FFI additions: in-memory certificate / private key loading
      // and "request but do not require" peer verification. Names are prefixed and
      // bound with link_name so they cannot clash with declarations above.

      #[allow(non_camel_case_types)]
      #[repr(transparent)]
      struct HY_X509 {
          _unused: c_void,
      }

      #[allow(non_camel_case_types)]
      #[repr(transparent)]
      struct HY_EVP_PKEY {
          _unused: c_void,
      }

      #[allow(non_camel_case_types)]
      #[repr(transparent)]
      struct HY_BIO {
          _unused: c_void,
      }

      extern "C" {
          #[link_name = "BIO_new_mem_buf"]
          fn hy_BIO_new_mem_buf(buf: *const c_void, len: libc::ssize_t) -> *mut HY_BIO;
          #[link_name = "BIO_free"]
          fn hy_BIO_free(bio: *mut HY_BIO) -> c_int;
          #[link_name = "PEM_read_bio_X509"]
          fn hy_PEM_read_bio_X509(
              bio: *mut HY_BIO, x: *mut *mut HY_X509, cb: *const c_void, u: *mut c_void,
          ) -> *mut HY_X509;
          #[link_name = "PEM_read_bio_PrivateKey"]
          fn hy_PEM_read_bio_PrivateKey(
              bio: *mut HY_BIO, x: *mut *mut HY_EVP_PKEY, cb: *const c_void,
              u: *mut c_void,
          ) -> *mut HY_EVP_PKEY;
          #[link_name = "d2i_X509"]
          fn hy_d2i_X509(
              out: *mut *mut HY_X509, inp: *mut *const u8, len: libc::c_long,
          ) -> *mut HY_X509;
          #[link_name = "d2i_AutoPrivateKey"]
          fn hy_d2i_AutoPrivateKey(
              out: *mut *mut HY_EVP_PKEY, inp: *mut *const u8, len: libc::c_long,
          ) -> *mut HY_EVP_PKEY;
          #[link_name = "X509_free"]
          fn hy_X509_free(x: *mut HY_X509);
          #[link_name = "EVP_PKEY_free"]
          fn hy_EVP_PKEY_free(k: *mut HY_EVP_PKEY);
          #[link_name = "SSL_CTX_use_certificate"]
          fn hy_SSL_CTX_use_certificate(ctx: *mut SSL_CTX, x: *mut HY_X509) -> c_int;
          #[link_name = "SSL_CTX_add1_chain_cert"]
          fn hy_SSL_CTX_add1_chain_cert(ctx: *mut SSL_CTX, x: *mut HY_X509) -> c_int;
          #[link_name = "SSL_CTX_use_PrivateKey"]
          fn hy_SSL_CTX_use_PrivateKey(ctx: *mut SSL_CTX, k: *mut HY_EVP_PKEY) -> c_int;
          #[link_name = "SSL_CTX_set_custom_verify"]
          fn hy_SSL_CTX_set_custom_verify(
              ctx: *mut SSL_CTX, mode: c_int,
              cb: Option<unsafe extern "C" fn(ssl: *mut SSL, out_alert: *mut u8) -> c_int>,
          );
      }

      fn hy_is_pem(data: &[u8]) -> bool {
          let start = data
              .iter()
              .position(|b| !b.is_ascii_whitespace())
              .unwrap_or(0);
          data[start..].starts_with(b"-----BEGIN")
      }

      // enum ssl_verify_result_t { ssl_verify_ok = 0, ... }
      unsafe extern "C" fn hy_verify_accept_any(_ssl: *mut SSL, _out_alert: *mut u8) -> c_int {
          0
      }

      impl Context {
          /// Certificate (chain) from memory, PEM or DER. First cert is the leaf.
          pub fn use_certificate_from_memory(&mut self, data: &[u8]) -> Result<()> {
              unsafe {
                  if hy_is_pem(data) {
                      let bio = hy_BIO_new_mem_buf(
                          data.as_ptr() as *const c_void,
                          data.len() as libc::ssize_t,
                      );
                      if bio.is_null() {
                          return Err(Error::TlsFail);
                      }
                      let mut count = 0;
                      let mut ok = true;
                      loop {
                          let x = hy_PEM_read_bio_X509(
                              bio,
                              ptr::null_mut(),
                              ptr::null(),
                              ptr::null_mut(),
                          );
                          if x.is_null() {
                              break;
                          }
                          let r = if count == 0 {
                              hy_SSL_CTX_use_certificate(self.as_mut_ptr(), x)
                          } else {
                              hy_SSL_CTX_add1_chain_cert(self.as_mut_ptr(), x)
                          };
                          hy_X509_free(x);
                          count += 1;
                          if r != 1 {
                              ok = false;
                              break;
                          }
                      }
                      hy_BIO_free(bio);
                      if ok && count > 0 {
                          Ok(())
                      } else {
                          Err(Error::TlsFail)
                      }
                  } else {
                      let mut p = data.as_ptr();
                      let x = hy_d2i_X509(ptr::null_mut(), &mut p, data.len() as libc::c_long);
                      if x.is_null() {
                          return Err(Error::TlsFail);
                      }
                      let r = hy_SSL_CTX_use_certificate(self.as_mut_ptr(), x);
                      hy_X509_free(x);
                      map_result(r)
                  }
              }
          }

          /// Private key from memory, PEM or DER (PKCS#8 or traditional).
          pub fn use_privkey_from_memory(&mut self, data: &[u8]) -> Result<()> {
              unsafe {
                  let key = if hy_is_pem(data) {
                      let bio = hy_BIO_new_mem_buf(
                          data.as_ptr() as *const c_void,
                          data.len() as libc::ssize_t,
                      );
                      if bio.is_null() {
                          return Err(Error::TlsFail);
                      }
                      let k = hy_PEM_read_bio_PrivateKey(
                          bio,
                          ptr::null_mut(),
                          ptr::null(),
                          ptr::null_mut(),
                      );
                      hy_BIO_free(bio);
                      k
                  } else {
                      let mut p = data.as_ptr();
                      hy_d2i_AutoPrivateKey(ptr::null_mut(), &mut p, data.len() as libc::c_long)
                  };
                  if key.is_null() {
                      return Err(Error::TlsFail);
                  }
                  let r = hy_SSL_CTX_use_PrivateKey(self.as_mut_ptr(), key);
                  hy_EVP_PKEY_free(key);
                  map_result(r)
              }
          }

          /// Request the peer's certificate (SSL_VERIFY_PEER) but accept the
          /// handshake regardless of it; the application inspects the cert itself.
          pub fn set_verify_peer_optional(&mut self) {
              unsafe {
                  hy_SSL_CTX_set_custom_verify(
                      self.as_mut_ptr(),
                      0x01, // SSL_VERIFY_PEER
                      Some(hy_verify_accept_any),
                  );
              }
          }
      }
      ''} >> src/tls/mod.rs
      cat ${pkgs.writeText "hytale-quiche-lib.rs" ''

      // ---- Hytale-fork additions (see tls/mod.rs).
      impl Config {
          pub fn load_cert_from_memory(&mut self, data: &[u8]) -> Result<()> {
              self.tls_ctx.use_certificate_from_memory(data)
          }

          pub fn load_priv_key_from_memory(&mut self, data: &[u8]) -> Result<()> {
              self.tls_ctx.use_privkey_from_memory(data)
          }

          pub fn verify_peer_optional(&mut self) {
              self.tls_ctx.set_verify_peer_optional();
          }
      }
      ''} >> src/lib.rs
      cat ${pkgs.writeText "hytale-quiche-ffi.rs" ''

      // ---- Hytale-fork FFI: signatures recovered from the Java binding
      // (FunctionDescriptor.of(C_INT, C_POINTER, C_POINTER, C_LONG) and
      // ofVoid(C_POINTER)).
      #[no_mangle]
      pub extern "C" fn quiche_config_load_cert(
          config: &mut Config, buf: *const u8, len: size_t,
      ) -> c_int {
          let data = unsafe { slice::from_raw_parts(buf, len) };

          match config.load_cert_from_memory(data) {
              Ok(_) => 0,

              Err(e) => e.to_c() as c_int,
          }
      }

      #[no_mangle]
      pub extern "C" fn quiche_config_load_priv_key(
          config: &mut Config, buf: *const u8, len: size_t,
      ) -> c_int {
          let data = unsafe { slice::from_raw_parts(buf, len) };

          match config.load_priv_key_from_memory(data) {
              Ok(_) => 0,

              Err(e) => e.to_c() as c_int,
          }
      }

      #[no_mangle]
      pub extern "C" fn quiche_config_verify_peer_optional(config: &mut Config) {
          config.verify_peer_optional();
      }
      ''} >> src/ffi.rs
    '';
    doCheck = false;
    installPhase = ''
      mkdir -p $out/lib
      find target -name libquiche.so -exec cp {} $out/lib/ \;
      cp -r include $out/
    '';
  };
  serverNatives = pkgs.runCommand "hytale-server-natives-aarch64.jar" {
    nativeBuildInputs = [ pkgs.zip ];
  } ''
    mkdir -p native/linux-x64
    cp ${quiche}/lib/libquiche.so                    native/linux-x64/libquiche.so
    cp ${lib.getLib pkgs.rocksdb}/lib/librocksdb.so  native/linux-x64/librocksdb.so
    cp ${lib.getLib pkgs.zstd}/lib/libzstd.so        native/linux-x64/libzstd.so
    chmod 644 native/linux-x64/*
    zip -0 -r $out native   # stored, not deflated: keeps the RUNPATH store references scannable
  '';
  # What the client gets as --java-exec: turns `java <jvm opts> -jar X <args>`
  # into a classpath launch with the overlay first. Enable-Native-Access from
  # the manifest must be restated once -jar is gone.
  serverJava = pkgs.writeShellScript "hytale-server-java" ''
    orig=("$@"); pre=(); post=(); jar=""
    while (($#)); do
      if [[ -z $jar && $1 == -jar ]]; then jar=$2; shift 2; continue; fi
      if [[ -z $jar ]]; then pre+=("$1"); else post+=("$1"); fi
      shift
    done
    [[ -n $jar ]] || exec ${java}/bin/java "''${orig[@]}"
    main=$(${pkgs.unzip}/bin/unzip -p "$jar" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r' | sed -n 's/^Main-Class: //p')
    # The third-party natives in the jar (Netty QUIC, zstd-jni, JLine) DO ship
    # aarch64 builds, but their loaders pick the resource by os.arch, which we
    # spoof. All of them fall back to java.library.path, so extract the aarch64
    # files into a per-jar directory (keyed by the jar's hash: survives game
    # updates) and serve them from there. Netty additionally derives the file
    # *name* from os.arch, hence the rename.
    ov=''${XDG_CACHE_HOME:-$HOME/.cache}/hytale/server/$(${pkgs.coreutils}/bin/sha256sum "$jar" | cut -c1-16)/lib
    if [[ ! -e $ov/.ready ]]; then
      rm -rf "$ov"; mkdir -p "$ov"
      ${pkgs.unzip}/bin/unzip -o -q -j "$jar" \
        'META-INF/native/libnetty_quiche42_linux_aarch_64.so' 'linux/aarch64/*' 'org/jline/nativ/Linux/arm64/*' \
        -d "$ov" 2>/dev/null || true
      [[ -e $ov/libnetty_quiche42_linux_aarch_64.so ]] && \
        mv "$ov/libnetty_quiche42_linux_aarch_64.so" "$ov/libnetty_quiche42_linux_x86_64.so"
      touch "$ov/.ready"
    fi
    # os.arch=amd64 steers Hytale's loaders to native/linux-x64, but the JDK's
    # FFM linker also derives its calling convention from os.arch (CABI.java),
    # which would emit x86-64 SysV downcall stubs on this aarch64 VM -> SIGSEGV
    # on the first foreign call (jline's isatty). Pin the ABI explicitly.
    exec ${java}/bin/java "''${pre[@]}" -Dos.arch=amd64 -Djdk.internal.foreign.CABI=LINUX_AARCH_64 \
      -Djava.library.path="$ov" --enable-native-access=ALL-UNNAMED \
      -cp "${serverNatives}:$jar" "''${main:-com.hypixel.hytale.Main}" "''${post[@]}"
  '';

  # x86_64 userland for the launcher, straight from cache.nixos.org. The FEX
  # Ubuntu image has GTK3 but no libwebkit2gtk-4.1 (FEX-Emu/RootFS
  # Configs/Ubuntu_24_04.json), and nix x86 libs can't be mixed into it
  # (glibc 2.42 vs 2.39). Keep nixpkgs-fex on nixos-unstable so every one of
  # these is a cache hit; nothing here is ever built locally.
  pkgsx86 = import inputs.nixpkgs-fex { system = "x86_64-linux"; };
  x86Libs = pkgs.buildEnv {
    name = "hytale-launcher-x86-libs";
    # DT_NEEDED + dlopen set of the launcher (same set the community FHS
    # flakes patchelf against); transitive deps resolve through nix RUNPATHs.
    paths = map lib.getLib (with pkgsx86; [
      glibc gcc.cc.lib
      gtk3 webkitgtk_4_1 glib glib-networking libsoup_3
      pango cairo gdk-pixbuf harfbuzz freetype fontconfig at-spi2-core dbus
      libglvnd mesa libdrm libxkbcommon wayland
      xorg.libX11 xorg.libXcomposite xorg.libXdamage xorg.libXext xorg.libXfixes
      xorg.libXrandr xorg.libXrender xorg.libXi xorg.libXcursor xorg.libXinerama
      xorg.libXtst xorg.libxshmfence
      alsa-lib libpulseaudio nss nspr openssl expat cups zlib
    ]);
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };
  schemaDirs = with pkgsx86; "${gtk3}/share/gsettings-schemas/${gtk3.name}:${gsettings-desktop-schemas}/share/gsettings-schemas/${gsettings-desktop-schemas.name}";

  # FEX RootFS for the launcher: the ELF interpreter, plus passthrough links
  # so `#!` scripts resolve. FEX looks a shebang interpreter up *only* under
  # the RootFS (GetShebangInterpFile) and returns ENOEXEC otherwise, which
  # would break xdg-open (browser login) and any /nix/store/... script.
  # x86 userland for the client under FEX: the same
  # nixpkgs approach as the launcher, so it shares the launcher's loader-only
  # RootFS and FEXServer (a second FEXServer is impossible while ~/.fex-emu
  # exists: FEX prefers that legacy data dir over FEX_APP_DATA_LOCATION and
  # allows one server per data dir). Deliberately WITHOUT libGL/libvulkan:
  # those come from FEX's thunks, which overlay RootFS paths (see fexRootfs),
  # and a copy on LD_LIBRARY_PATH would shadow them with emulated llvmpipe.
  clientX86Libs = pkgs.buildEnv {
    name = "hytale-client-x86-libs";
    paths = map lib.getLib (with pkgsx86; [
      glibc gcc.cc.lib
      icu openssl zlib expat dbus udev
      xorg.libX11 xorg.libXext xorg.libXcursor xorg.libXi xorg.libXrandr xorg.libXfixes
      xorg.libXrender xorg.libXinerama xorg.libXScrnSaver xorg.libXxf86vm
      xorg.libXcomposite xorg.libXdamage xorg.libxshmfence xorg.libxcb
      libxkbcommon wayland libdecor
      alsa-lib libpulseaudio libogg libvorbis libopus libpng libjpeg
      libbsd libunwind
    ]);
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };

  # FEX's guest thunk libraries under the sonames the client asks for, as
  # regular files (FEX re-resolves absolute RootFS symlinks inside the RootFS,
  # which is why the RootFS decoys below were never reached). First on the
  # guest LD_LIBRARY_PATH -> GL/Vulkan go to the host driver, no overlay needed.
  fexGuestThunks = pkgs.runCommand "hytale-fex-guest-thunks" {
    nativeBuildInputs = [ pkgs.patchelf ];
  } ''
    mkdir -p $out/lib
    cp ${fex}/share/fex-emu/GuestThunks/libGL-guest.so      $out/lib/libGL.so.1
    cp ${fex}/share/fex-emu/GuestThunks/libGL-guest.so      $out/lib/libGL.so
    cp ${fex}/share/fex-emu/GuestThunks/libEGL-guest.so     $out/lib/libEGL.so.1
    cp ${fex}/share/fex-emu/GuestThunks/libvulkan-guest.so  $out/lib/libvulkan.so.1
    cp ${fex}/share/fex-emu/GuestThunks/libwayland-client-guest.so $out/lib/libwayland-client.so.0
    chmod u+w $out/lib/*
    # The thunks reference __gxx_personality_v0 without depending on libstdc++
    # (a stock guest has it loaded globally already); declare it, the guest
    # x86 libstdc++ is on LD_LIBRARY_PATH via clientX86Libs.
    for f in $out/lib/*; do
      patchelf --add-needed libstdc++.so.6 --add-needed libgcc_s.so.1 "$f"
    done
  '';

  # Control for HYTALE_FEX_THUNKS=0: emulated x86 Mesa (llvmpipe), no thunks.
  clientX86GL = pkgs.buildEnv {
    name = "hytale-client-x86-gl";
    paths = map lib.getLib (with pkgsx86; [ libglvnd mesa libdrm ]);
    pathsToLink = [ "/lib" ];
    ignoreCollisions = true;
  };

  # Diagnostic (HYTALE_FEX_STACKCHK=1): x86_64 shim preloaded into the guest
  # that turns glibc's silent "*** stack smashing detected ***" into a guest
  # backtrace on stderr (-> fex-client.log) before aborting. Built with the
  # same cross clang the nixpkgs FEX package uses for its guest thunks.
  x86StackChk = pkgs.runCommand "hytale-x86-stackchk" {
    nativeBuildInputs = [ pkgs.pkgsCross.gnu64.buildPackages.clang ];
  } ''
    mkdir -p $out/lib
    cat > shim.c <<'EOF'
    #define _GNU_SOURCE
    #include <execinfo.h>
    #include <stdlib.h>
    #include <unistd.h>
    #include <stdio.h>
    #include <sys/syscall.h>
    #include <errno.h>
    #include <sys/uio.h>
    #include <string.h>
    #include <pthread.h>
    /* __stack_chk_fail is reached by `sub rax, fs:[0x28]; jne` in the caller, so
       on entry rax == frame_canary - tls_canary. A naked asm entry saves rax
       and the caller's rsp before C code can touch them. */
    void hy_stack_chk_fail_c(unsigned long hy_diff, unsigned long hy_callsp);
    __asm__(".globl __stack_chk_fail\n.type __stack_chk_fail,@function\n__stack_chk_fail:\n"
            "  mov %rax, %rdi\n"
            "  mov %rsp, %rsi\n"
            "  jmp hy_stack_chk_fail_c\n");
    void hy_stack_chk_fail_c(unsigned long hy_diff, unsigned long hy_callsp) {
      void* bt[64];
      int n = backtrace(bt, 64);
      unsigned long tls_canary; __asm__("mov %%fs:0x28, %0" : "=r"(tls_canary));
      unsigned long tcb; __asm__("mov %%fs:0, %0" : "=r"(tcb));
      char msg[256];
      int l = snprintf(msg, sizeof msg, "*** stack smashing detected (guest, %d frames) tid=%ld ***\n"
                       "    tls canary=%#lx frame canary=%#lx (diff %#lx) tcb=%#lx pthread_self=%#lx\n",
                       n, (long)syscall(186), tls_canary, tls_canary + hy_diff, hy_diff, tcb, (unsigned long)pthread_self());
      write(2, msg, l);
      /* The smashed frame lies just above our return address: dump it. */
      unsigned long* sp = (unsigned long*)hy_callsp;
      for (int i = 0; i < 40; i += 4) {
        l = snprintf(msg, sizeof msg, "    [ret+%03x] %016lx %016lx %016lx %016lx\n", i * 8, sp[i], sp[i+1], sp[i+2], sp[i+3]);
        write(2, msg, l);
      }
      backtrace_symbols_fd(bt, n, 2);
      abort();
    }
    /* Guest-side SIGSEGV/SIGBUS reporter: NativeAOT only handles faults in
       managed code and chains to the previous handler otherwise, so this runs
       for native faults. Prints guest RIP, fault address and a backtrace, then
       restores SIG_DFL and returns to re-fault (dump as usual). */
    #include <signal.h>
    #include <ucontext.h>
    #include <fcntl.h>
    #include <dlfcn.h>
    static void hy_fault(int sig, siginfo_t* si, void* uc) {
      ucontext_t* u = (ucontext_t*)uc;
      greg_t* g = u->uc_mcontext.gregs;
      char msg[512];
      int l = snprintf(msg, sizeof msg, "*** guest signal %d at rip=%#llx addr=%p code=%d ***\n",
                       sig, (unsigned long long)g[REG_RIP], si->si_addr, si->si_code);
      write(2, msg, l);
      /* Attribute RIP and code-looking stack values without dladdr (takes
         loader locks): scan /proc/thread-self/maps with raw syscalls. */
      {
        static char buf[1 << 17]; ssize_t n = -1;
        int fd = syscall(257, -100, "/proc/thread-self/maps", O_RDONLY, 0);
        if (fd >= 0) { n = read(fd, buf, sizeof buf - 1); close(fd); }
        if (n > 0) {
          buf[n] = 0;
          unsigned long long* sp = (unsigned long long*)g[REG_RSP];
          unsigned long long want[17]; int nw = 0;
          want[nw++] = (unsigned long long)g[REG_RIP];
          for (int i = 0; i < 16; i++) want[nw++] = sp[i];
          for (int w = 0; w < nw; w++) {
            unsigned long long v = want[w];
            if (v < 0x10000ULL) continue;
            char* line = buf;
            while (line && *line) {
              char* nl = strchr(line, '\n'); if (nl) *nl = 0;
              unsigned long long lo = 0, hi = 0, off = 0; char perms[8] = {0}; char path[256] = {0};
              int k = sscanf(line, "%llx-%llx %7s %llx %*s %*s %255s", &lo, &hi, perms, &off, path);
              if (k >= 4 && v >= lo && v < hi) {
                if (perms[2] == 'x') {
                  l = snprintf(msg, sizeof msg, "    %s %#llx = %s + %#llx\n", w == 0 ? "rip  " : "stack", v, path[0] ? path : "?", v - lo + off);
                  write(2, msg, l);
                }
                if (nl) *nl = '\n';
                break;
              }
              if (nl) *nl = '\n';
              line = nl ? nl + 1 : 0;
            }
          }
        }
      }
      l = snprintf(msg, sizeof msg, "    rax=%#llx rbx=%#llx rcx=%#llx rdx=%#llx rsi=%#llx rdi=%#llx rbp=%#llx rsp=%#llx r8=%#llx r9=%#llx r12=%#llx r14=%#llx\n",
                   (unsigned long long)g[REG_RAX], (unsigned long long)g[REG_RBX], (unsigned long long)g[REG_RCX], (unsigned long long)g[REG_RDX],
                   (unsigned long long)g[REG_RSI], (unsigned long long)g[REG_RDI], (unsigned long long)g[REG_RBP], (unsigned long long)g[REG_RSP],
                   (unsigned long long)g[REG_R8], (unsigned long long)g[REG_R9], (unsigned long long)g[REG_R12], (unsigned long long)g[REG_R14]);
      write(2, msg, l);
      unsigned char* ip = (unsigned char*)g[REG_RIP];
      if ((unsigned long long)ip >= 4096) {
        l = snprintf(msg, sizeof msg, "    bytes: %02x %02x %02x %02x %02x %02x %02x %02x\n", ip[0],ip[1],ip[2],ip[3],ip[4],ip[5],ip[6],ip[7]);
        write(2, msg, l);
      }
      unsigned long long* sp = (unsigned long long*)g[REG_RSP];
      l = snprintf(msg, sizeof msg, "    stack: [rsp]=%#llx [rsp+8]=%#llx [rsp+16]=%#llx [rsp+24]=%#llx\n", sp[0], sp[1], sp[2], sp[3]);
      write(2, msg, l);
      void* bt[48]; int n = backtrace(bt, 48); backtrace_symbols_fd(bt, n, 2);
      signal(sig, SIG_DFL);
    }
    /* Background recorder: every few seconds write the guest loader's object
       list (dl_iterate_phdr: base + PT_LOAD ranges + name, incl. dlopen'd
       libs) and the guest's view of /proc/self/maps to
       $HOME/.cache/hytale/guest-objects.txt, so a crash RIP in a mapping the
       host cannot name can be attributed afterwards. */
    #include <link.h>
    #include <pthread.h>
    static int hy_phdr_cb(struct dl_phdr_info* info, size_t sz, void* data) {
      FILE* f = data; (void)sz;
      for (int i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr)* ph = &info->dlpi_phdr[i];
        if (ph->p_type != PT_LOAD) continue;
        unsigned long lo = info->dlpi_addr + ph->p_vaddr, hi = lo + ph->p_memsz;
        fprintf(f, "%#lx-%#lx %c%c%c base=%#lx off=%#lx %s\n", lo, hi,
                (ph->p_flags & PF_R) ? 'r' : '-', (ph->p_flags & PF_W) ? 'w' : '-', (ph->p_flags & PF_X) ? 'x' : '-',
                (unsigned long)info->dlpi_addr, (unsigned long)ph->p_offset, info->dlpi_name && *info->dlpi_name ? info->dlpi_name : "(main)");
      }
      return 0;
    }
    static void* hy_recorder(void* arg) {
      (void)arg;
      char path[512]; const char* home = getenv("HOME");
      snprintf(path, sizeof path, "%s/.cache/hytale/guest-objects.txt", home ? home : "/tmp");
      for (;;) {
        char tmp[520]; snprintf(tmp, sizeof tmp, "%s.tmp", path);
        FILE* (*real_fopen)(const char*, const char*) = dlsym(RTLD_NEXT, "fopen");
        FILE* f = real_fopen(tmp, "w");
        if (f) {
          fprintf(f, "## dl_iterate_phdr\n");
          dl_iterate_phdr(hy_phdr_cb, f);
          fprintf(f, "## /proc/self/maps (guest view)\n");
          int fd = syscall(257, -100, "/proc/self/maps", O_RDONLY, 0);
          if (fd >= 0) { char b[4096]; ssize_t n; while ((n = read(fd, b, sizeof b)) > 0) fwrite(b, 1, n, f); close(fd); }
          fclose(f); rename(tmp, path);
        }
        sleep(3);
      }
      return 0;
    }
    __attribute__((constructor)) static void hy_install(void) {
      void* warm[4]; backtrace(warm, 4);   /* first backtrace() dlopens libgcc: do it now, not in a handler */
      pthread_t t; pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setdetachstate(&a, PTHREAD_CREATE_DETACHED);
      pthread_create(&t, &a, hy_recorder, 0);
      struct sigaction sa; memset(&sa, 0, sizeof sa);
      sa.sa_sigaction = hy_fault; sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER;
      sigaction(SIGSEGV, &sa, 0); sigaction(SIGBUS, &sa, 0);
    }
    /* HYTALE_FEX_NOMODSCAN=1: starve sentry-native's module finder. It starts
       from /proc/self/maps and then mmaps/munmaps every module's ELF file to
       read build-ids; under an emulator those unmaps hit the emulator's own
       code-tracking for live libraries. glibc reads the file once at startup
       (main-thread stack bounds), so the first 20 s stay allowed. */
    #include <time.h>
    #include <stdarg.h>
    static time_t hy_t0;
    static int hy_deny_maps(const char* path) {
      if (!getenv("HYTALE_FEX_NOMODSCAN") || !path || strcmp(path, "/proc/self/maps") != 0) return 0;
      if (!hy_t0) hy_t0 = time(0);
      return time(0) - hy_t0 > 20;
    }
    int open(const char* path, int flags, ...) {
      mode_t mode = 0;
      if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
      if (hy_deny_maps(path)) { errno = ENOENT; return -1; }
      return syscall(257 /* openat */, -100 /* AT_FDCWD */, path, flags, mode);
    }
    int open64(const char* path, int flags, ...) {
      mode_t mode = 0;
      if (flags & O_CREAT) { va_list ap; va_start(ap, flags); mode = va_arg(ap, mode_t); va_end(ap); }
      if (hy_deny_maps(path)) { errno = ENOENT; return -1; }
      return syscall(257, -100, path, flags, mode);
    }
    FILE* fopen(const char* path, const char* mode) {
      if (hy_deny_maps(path)) { errno = ENOENT; return 0; }
      FILE* (*real)(const char*, const char*) = dlsym(RTLD_NEXT, "fopen");
      return real(path, mode);
    }
    FILE* fopen64(const char* path, const char* mode) {
      if (hy_deny_maps(path)) { errno = ENOENT; return 0; }
      FILE* (*real)(const char*, const char*) = dlsym(RTLD_NEXT, "fopen64");
      return real(path, mode);
    }
    /* HYTALE_FEX_NOVMREAD=1: make sentry-native's module reader use its memcpy
       fallback instead of a syscall a GC signal can interrupt. */
    ssize_t process_vm_readv(pid_t pid, const struct iovec* l, unsigned long ln,
                             const struct iovec* r, unsigned long rn, unsigned long f) {
      (void)pid; (void)ln; (void)rn; (void)f; (void)l; (void)r;
      if (getenv("HYTALE_FEX_NOVMREAD")) { errno = EPERM; return -1; }
      return syscall(310 /* __NR_process_vm_readv x86_64 */, pid, l, ln, r, rn, f);
    }
    EOF
    x86_64-unknown-linux-gnu-clang -shared -fPIC -O1 -fno-stack-protector -o $out/lib/libstackchk.so shim.c -ldl -lpthread
  '';

  fexRootfs = pkgs.runCommand "hytale-fex-rootfs" { } ''
    mkdir -p $out/lib64 $out/bin $out/usr/bin $out/usr/lib/x86_64-linux-gnu
    cp ${pkgsx86.glibc}/lib/ld-linux-x86-64.so.2 $out/lib64/
    ln -s /nix $out/nix
    ln -s /bin/sh $out/bin/sh
    ln -s /bin/bash $out/bin/bash
    ln -s /usr/bin/env $out/usr/bin/env
    # Thunk decoys: FEX's ThunksDB overlays these exact RootFS paths with its
    # guest thunk libraries (Data/ThunksDB.json, @PREFIX_LIB@), forwarding GL
    # and Vulkan to the host driver. The targets only matter with thunks off.
    for l in libGL.so.1 libGL.so; do
      ln -s ${lib.getLib pkgsx86.libglvnd}/lib/libGL.so.1 $out/usr/lib/x86_64-linux-gnu/$l
    done
    ln -s ${lib.getLib pkgsx86.vulkan-loader}/lib/libvulkan.so.1 $out/usr/lib/x86_64-linux-gnu/libvulkan.so.1
  '';

  # Seed only. The launcher self-updates into ~/.local/share/Hytale and the
  # wrapper prefers that copy. Version + sha256 (hex -> SRI) from
  # https://launcher.hytale.com/version/release/launcher.json
  launcherVersion = "2026.08.28-3d62362";
  launcherSeed = pkgs.stdenvNoCC.mkDerivation {
    pname = "hytale-launcher-seed";
    version = launcherVersion;
    src = pkgs.fetchurl {
      url = "https://launcher.hytale.com/builds/release/linux/amd64/hytale-launcher-${launcherVersion}.zip";
      hash = "sha256-DLFvaRSfwilOkkdOz4rcnmsQTFQZvtIITmFBfhV67hg=";
    };
    nativeBuildInputs = [ pkgs.unzip ];
    sourceRoot = ".";
    dontFixup = true; # x86_64 ELF: no strip/patchelf on aarch64
    installPhase = ''
      mkdir -p $out
      cp -r ./* $out/
      rm -f $out/env-vars
      chmod +x $out/hytale-launcher
    '';
  };

  # Private FEX config namespace. SetupClient() takes the RootFS from
  # whichever FEXServer answers <uid>.FEXServer.Socket -- Steam's, if it is
  # running -- so Hytale gets its own socket name and therefore its own server.
  fexConfigDir = pkgs.linkFarm "hytale-fex-config" [
    {
      name = "Config.json";
      path = pkgs.writeText "hytale-fex-Config.json" (builtins.toJSON {
        Config = {
          RootFS = "${fexRootfs}";
          ServerSocketPath = "hytale.FEXServer.Socket";
        };
        ThunksDB = { };
      });
    }
    {
      # Host GL (the client renders
      # OpenGL 4.6 through SDL3/GLX) and Vulkan through FEX's thunks.
      name = "AppConfig/HytaleClient.json";
      path = pkgs.writeText "hytale-fex-HytaleClient.json" (builtins.toJSON {
        Config = { };
        ThunksDB = { GL = 1; EGL = 1; Vulkan = 1; WaylandClient = 1; };
      });
    }
  ];

  # binfmt hook (see fex-binfmt in fex.nix). Every x86 exec in a process tree
  # that carries FEX_BINFMT_HOOK lands here (launcher updater, WebKit helper
  # processes, HytaleClient). Only HytaleClient is redirected; everything else
  # goes to FEX with argv and env untouched, so the launcher's tree is never
  # modified and wharf patching always sees the official binaries.
  hook = pkgs.writeShellScript "hytale-binfmt-hook" ''
    # argv: <pathname passed to execve> <original argv[0]> <args...>
    target=$(${pkgs.coreutils}/bin/readlink -f "/proc/$$/fd/''${FEX_EXECVEFD:-0}" 2>/dev/null || printf '%s' "$1")
    case $target in
      */Hytale/install/*/package/game/*/Client/HytaleClient) ;;
      *) exec ${fex}/bin/FEX "$@" ;;
    esac

    # Launcher passes `--java-exec <its x86 JRE>`; swap in the native one.
    args=(); next_is_java=0
    for a in "''${@:3}"; do
      if (( next_is_java )); then args+=("${serverJava}"); next_is_java=0; continue; fi
      [[ $a == --java-exec ]] && next_is_java=1
      args+=("$a")
    done

    # Launcher-only (nix x86 userland / WebKitGTK) knobs must not reach the game.
    unset LD_LIBRARY_PATH GIO_EXTRA_MODULES GDK_PIXBUF_MODULE_FILE __EGL_VENDOR_LIBRARY_FILENAMES \
          GDK_BACKEND LIBGL_ALWAYS_SOFTWARE WEBKIT_DISABLE_COMPOSITING_MODE WEBKIT_DISABLE_DMABUF_RENDERER \
          WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS NO_AT_BRIDGE

    # Same loader-only RootFS and FEXServer as the launcher; the userland
    # is nixpkgs x86_64 on LD_LIBRARY_PATH (see clientX86Libs), GL/Vulkan
    # via thunks (AppConfig/HytaleClient.json + RootFS decoys).
    # HYTALE_FEX_VIDEO=x11|wayland (default x11: GL thunk over GLX);
    # HYTALE_FEX_THUNKS=0 -> emulated x86 Mesa/llvmpipe, no thunks (control).
    if [[ ''${HYTALE_FEX_THUNKS:-1} != 0 ]]; then
      export LD_LIBRARY_PATH=${fexGuestThunks}/lib:${clientX86Libs}/lib:/usr/lib/x86_64-linux-gnu
    else
      export LD_LIBRARY_PATH=${clientX86GL}/lib:${clientX86Libs}/lib
      export LIBGL_ALWAYS_SOFTWARE=1 LIBGL_DRIVERS_PATH=${lib.getLib pkgsx86.mesa}/lib/dri __GLX_VENDOR_LIBRARY_NAME=mesa
    fi
    v=''${HYTALE_FEX_VIDEO:-x11}
    export SDL_VIDEO_DRIVER=$v SDL_VIDEODRIVER=$v
    # HalfBarrierTSOAlways (see the fex override): 1 = every scalar TSO
    # access as ldur/stur+dmb up front (no SIGBUS backpatching; slower).
    # Stock behaviour (0) is safe again with the signal fixes in place.
    export FEX_HALFBARRIERTSOALWAYS=''${FEX_HALFBARRIERTSOALWAYS:-0}
    # NativeAOT GC suspension must not need register edits to the signal
    # context (FEX drops those for signals landing in JIT code):
    # conservative stack reporting + in-place suspension. Required.
    export DOTNET_gcConservative=''${DOTNET_gcConservative:-1}
    # Every GC stops the world by signalling all threads, and a signal is
    # expensive under FEX (frame setup, state spill, sigreturn). A 512 MB
    # gen0 budget means far fewer collections for a modest memory cost.
    export DOTNET_GCgen0size=''${DOTNET_GCgen0size:-0x20000000}
    # Guest-only preload (FEX's own aarch64 ld.so just warns and ignores it).
    [[ ''${HYTALE_FEX_STACKCHK:-0} == 1 ]] && export LD_PRELOAD=${x86StackChk}/lib/libstackchk.so
    # Per-run stderr capture (the launcher swallows the child's stderr).
    log=''${XDG_CACHE_HOME:-$HOME/.cache}/hytale/fex-client.log
    exec ${fex}/bin/FEX "$1" "$2" "''${args[@]}" 2>"$log"
  '';

  hytale = pkgs.writeShellApplication {
    name = "hytale";
    runtimeInputs = [ pkgs.coreutils pkgs.xdg-utils ];
    text = ''
      # programs.hytale.environment (declarative knobs; a shell export still wins
      # because every consumer below uses ''${VAR:-default}).
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "if [ -z \"\${${k}+x}\" ]; then export ${k}=${lib.escapeShellArg v}; fi") cfg.environment)}

      data=''${XDG_DATA_HOME:-$HOME/.local/share}/Hytale
      cache=''${XDG_CACHE_HOME:-$HOME/.cache}/hytale
      mkdir -p "$cache/fex" "$data/tmp"

      # Go, GnuTLS (glib-networking) and OpenSSL-under-.NET all honour this;
      # the Ubuntu OpenSSL default (/usr/lib/ssl) does not exist here.
      export SSL_CERT_FILE=''${SSL_CERT_FILE:-/etc/ssl/certs/ca-bundle.crt}
      # Patch staging on the same filesystem as the install (not tmpfs /tmp).
      export TMPDIR=$data/tmp

      # Prefer the launcher's self-updated copy over the Nix seed
      # (glob order == date-version order).
      launcher=${launcherSeed}/hytale-launcher
      for l in "$data"/install/release/package/launcher/*/hytale-launcher; do
        [[ -x $l ]] && launcher=$l
      done

      # The old design swapped shims into the game tree; a leftover there
      # shows up as "exec format error" from the launcher. Warn early.
      c=$data/install/release/package/game/latest/Client/HytaleClient
      if [[ -e $c && $(head -c 4 "$c" 2>/dev/null) != $'\x7fELF' ]]; then
        echo "hytale: $c is not an ELF (leftover shim?) - restore it or rm -rf .../package/game" >&2
      fi

      # FEX: private config dir (own RootFS + own FEXServer), private code cache.
      export FEX_APP_CONFIG_LOCATION=${fexConfigDir}/
      export FEX_APP_CACHE_LOCATION=$cache/fex/
      export FEX_BINFMT_HOOK=${hook}

      # Launcher (Wails/WebKitGTK) on the nix x86 userland. nix ld.so has no
      # /usr/lib search path, so its libs come through LD_LIBRARY_PATH; the
      # hook drops it again before the game. Native children (xdg-open) skip
      # the foreign-arch entries harmlessly.
      export LD_LIBRARY_PATH=${x86Libs}/lib
      export XDG_DATA_DIRS=${schemaDirs}''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}
      export GIO_EXTRA_MODULES=${pkgsx86.glib-networking}/lib/gio/modules
      export GDK_PIXBUF_MODULE_FILE=${pkgsx86.gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
      export __EGL_VENDOR_LIBRARY_FILENAMES=${pkgsx86.mesa}/share/glvnd/egl_vendor.d/50_mesa.json
      unset GTK_MODULES GTK_IM_MODULE GTK_PATH GTK_EXE_PREFIX
      export NO_AT_BRIDGE=1
      export GDK_BACKEND=x11 LIBGL_ALWAYS_SOFTWARE=1
      export WEBKIT_DISABLE_COMPOSITING_MODE=1 WEBKIT_DISABLE_DMABUF_RENDERER=1
      export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1   # no bwrap-under-FEX for local UI content
      export HYTALE_LAUNCHER_NO_TEST_RUN_BINARIES=1
      # Go's SIGURG-based async preemption corrupts guest state under FEX on
      # Oryon-3 (random early-init panics). Cooperative preemption only.
      export GODEBUG=asyncpreemptoff=1

      # .NET (client): no ICU at all (the 0.6.3+ abort is inside globalization
      # init), and no W^X double-mapping of JIT pages under an emulator.
      export DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1
      export DOTNET_EnableWriteXorExecute=0

      exec ${fex}/bin/FEX "$launcher" "$@"
    '';
  };
  # Desktop entry. The launcher zip is just the Wails binary; its app icon is
  # embedded as a PNG resource, so pull the largest PNG out of the ELF.
  hytaleIcon = pkgs.runCommand "hytale-icon" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p $out/share/icons/hicolor/256x256/apps
    python3 - "${launcherSeed}/hytale-launcher" "$out/share/icons/hicolor/256x256/apps/hytale.png" <<'PY'
    import sys, re
    data = open(sys.argv[1], 'rb').read()
    best = b""
    for m in re.finditer(b"\x89PNG\r\n\x1a\n", data):
        end = data.find(b"IEND", m.start())
        if end == -1: continue
        png = data[m.start():end + 8]
        if len(png) > len(best): best = png
    if best: open(sys.argv[2], 'wb').write(best)
    else: print("no embedded PNG found; desktop entry will use a generic icon")
    PY
  '';
  hytaleDesktop = pkgs.makeDesktopItem {
    name = "hytale";
    desktopName = "Hytale";
    comment = "Hytale launcher and client (x86_64 under FEX)";
    exec = "${hytale}/bin/hytale";
    icon = "hytale";
    terminal = false;
    categories = [ "Game" ];
    startupNotify = false;
  };

  cfg = config.programs.hytale;
in
{
  options.programs.hytale = {
    enable = lib.mkEnableOption "Hytale on aarch64: x86_64 launcher and client under FEX, native server";

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = lib.literalExpression ''
        {
          DOTNET_GCgen0size = "0x40000000";
          HYTALE_FEX_VIDEO = "wayland";
        }
      '';
      description = ''
        Runtime knobs (see README) exported by the `hytale` wrapper, so they
        also apply to the desktop entry. A variable already set in the
        launching shell takes precedence.
      '';
    };

    coredumps = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Raise systemd-coredump size limits so FEX client dumps are complete.
        FEX cores are huge uncompressed (guest address-space reservations dump
        as zeros) but compress to a few hundred MB; the caps are on the raw
        size. Only needed for debugging; also run `ulimit -c unlimited` in the
        shell that launches the game.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = config.programs.fex.enable or false;
      message = "programs.hytale needs programs.fex.enable = true (the x86_64 launcher runs through the FEX binfmt shim).";
    }];

    environment.systemPackages = [ hytale hytaleDesktop hytaleIcon ];

    systemd.coredump.settings.Coredump = lib.mkIf cfg.coredumps {
      ProcessSizeMax = "1T";
      ExternalSizeMax = "1T";
      MaxUse = "20G";
    };
  };
}
