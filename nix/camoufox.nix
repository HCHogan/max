# camoufox, the Firefox that run_code's programs drive with Playwright; see
# "浏览器" in docs/rust-rewrite.md. It isn't in nixpkgs: this is the release
# build, patched to find its libraries in the store, as the Haskell version
# packaged it. camoufox-js finds it here (runner.nix), with uBlock Origin,
# which it would otherwise download into this read-only directory.
{ pkgs }:
let
  version = "152.0.4";
  release = "beta.28";
  archive =
    {
      x86_64-linux = {
        arch = "x86_64";
        hash = "sha256-kk8xCczW1HzWoDhNZ6NF+t+XXUi2MZ+Nu9WVTFiJgr0=";
      };
      aarch64-linux = {
        arch = "arm64";
        hash = "sha256-OhBaL8kp6Ap5tLf84sk+1ixPssh388HtKl1mocT+lo8=";
      };
    }
    .${pkgs.stdenv.hostPlatform.system}
      or (throw "camoufox: no release for ${pkgs.stdenv.hostPlatform.system}");
  ublockOrigin = pkgs.fetchurl {
    url = "https://addons.mozilla.org/firefox/downloads/file/4888680/ublock_origin-1.72.2.xpi";
    hash = "sha256-QMMVsNp4cYaBVez656UKWN+gkgrr2GXgCCFJhvG3xXg=";
  };
  # What Firefox links to, and what it opens itself later (sound, GL, D-Bus).
  libraries = with pkgs; [
    stdenv.cc.cc.lib
    glib
    gtk3
    nss
    nspr
    dbus
    dbus-glib
    alsa-lib
    cups
    libdrm
    libgbm
    libGL
    libxkbcommon
    libpulseaudio
    pciutils
    zlib
    libx11
    libxext
    libxfixes
    libxrender
    libxrandr
    libxcomposite
    libxdamage
    libxcb
    libxt
    libxtst
    libxi
    libxscrnsaver
    at-spi2-core
    pango
    cairo
    fontconfig
    freetype
  ];
in
pkgs.stdenv.mkDerivation {
  pname = "camoufox";
  version = "${version}-${release}";
  src = pkgs.fetchurl {
    url = "https://github.com/daijro/camoufox/releases/download/v${version}-${release}/camoufox-${version}-${release}-lin.${archive.arch}.zip";
    inherit (archive) hash;
  };
  nativeBuildInputs = [
    pkgs.unzip
    pkgs.patchelfUnstable
    pkgs.autoPatchelfHook
  ];
  # Firefox's binaries have ELF sections that plain patchelf may overwrite;
  # nixpkgs' firefox-bin keeps them the same way.
  patchelfFlags = [ "--no-clobber-old-sections" ];
  buildInputs = libraries;
  runtimeDependencies = libraries;
  sourceRoot = ".";
  unpackPhase = "unzip -q $src -d camoufox";
  installPhase = ''
    mkdir -p $out/lib/camoufox/addons/UBO
    cp -r camoufox/. $out/lib/camoufox/
    unzip -q ${ublockOrigin} -d $out/lib/camoufox/addons/UBO
    # camoufox-js checks the version it launches against this.
    echo '${builtins.toJSON { inherit version release; }}' > $out/lib/camoufox/version.json
    chmod -R u+w $out
  '';
  doInstallCheck = true;
  installCheckPhase = "$out/lib/camoufox/camoufox --version";
  meta.platforms = [
    "x86_64-linux"
    "aarch64-linux"
  ];
}
