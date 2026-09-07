{ pkgs }:
pkgs.pkgsCross.wasi32.stdenv.mkDerivation {
  pname = "max-codemode-js";
  version = "0.16.2";
  src = pkgs.fetchurl {
    name = "quickjs-ng-0.16.2.tar.gz";
    url = "https://codeload.github.com/quickjs-ng/quickjs/tar.gz/refs/tags/v0.16.2";
    sha256 = "97c80625b26775a4c7ca618c004d4ea24cf99cbf867e4eba78bd927a8b23d106";
  };
  nativeBuildInputs = [ pkgs.python3 ];
  dontConfigure = true;
  dontFixup = true;
  hardeningDisable = [ "all" ];
  buildPhase = ''
    runHook preBuild
    # wasi-libc groups its ambient syscall wrappers in one archive member.
    # Replace that member with the guest's explicit stubs, not linker imports.
    cp ${pkgs.pkgsCross.wasi32.wasilibc}/lib/libc.a libc.a
    $AR d libc.a __wasilibc_real.o
    $CC -O2 -DNDEBUG -D_GNU_SOURCE -D_WASI_EMULATED_SIGNAL -I. -L. \
      -nostartfiles ${../codemode/quickjs.c} \
      quickjs.c dtoa.c libregexp.c libunicode.c \
      -lm -Wl,--entry=_start -Wl,-z,stack-size=2097152 \
      -o quickjs.wasm
    python3 ${../scripts/check-codemode-imports.py} quickjs.wasm
    runHook postBuild
  '';
  installPhase = ''
    mkdir -p $out
    cp quickjs.wasm LICENSE $out/
  '';
}
