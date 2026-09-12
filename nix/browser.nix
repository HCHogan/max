{ pkgs }:
let
  inherit (pkgs) lib;
  assets = import ./camoufox-browser.nix { inherit pkgs; };
  runtimeLibraries = with pkgs; [
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
  browser = pkgs.stdenv.mkDerivation {
    pname = "max-camoufox";
    version = "${assets.version}-${assets.release}";
    src = assets.archive;
    nativeBuildInputs = [
      pkgs.unzip
      pkgs.patchelfUnstable
      pkgs.autoPatchelfHook
    ];
    # Firefox binaries use ELF sections that ordinary patchelf may overwrite.
    # Match nixpkgs' firefox-bin packaging to preserve those sections.
    patchelfFlags = [ "--no-clobber-old-sections" ];
    buildInputs = runtimeLibraries;
    sourceRoot = ".";
    unpackPhase = "unzip -q $src -d browser";
    installPhase = ''
      mkdir -p $out/lib/camoufox/addons/UBO
      cp -r browser/. $out/lib/camoufox/
      unzip -q ${assets.ublockOrigin} -d $out/lib/camoufox/addons/UBO
      cp ${assets.geoLiteCity} $out/lib/camoufox/GeoLite2-City.mmdb
      printf '%s\n' '${
        builtins.toJSON { inherit (assets) version release; }
      }' > $out/lib/camoufox/version.json
      chmod -R u+w $out
    '';
    runtimeDependencies = runtimeLibraries;
    doInstallCheck = true;
    installCheckPhase = ''
      runHook preInstallCheck
      $out/lib/camoufox/camoufox --version
      runHook postInstallCheck
    '';
  };
  fonts = pkgs.makeFontsConf {
    fontDirectories = [
      pkgs.dejavu_fonts
      pkgs.noto-fonts-cjk-sans
      pkgs.noto-fonts-color-emoji
    ];
  };
in
pkgs.buildNpmPackage {
  pname = "max-browser";
  version = "2.4.0";
  src = pkgs.fetchzip {
    extension = "tar.gz";
    url = "https://codeload.github.com/whit3rabbit/camoufox-mcp/tar.gz/e5057f3bcf5bae9b2bc5d9c43972e89b6519ee9c";
    hash = "sha256-OLAR5Zu9oxzK8a3yC4rFntONJKtljnoV6QpklOZBDtU=";
  };
  nodejs = pkgs.nodejs_22;
  npmDepsHash = "sha256-SclgPb+zf+wWz6Om4ggP64Ep0WdGoPgE/og1Iv88ufM=";
  npmFlags = [ "--ignore-scripts" ];
  nativeBuildInputs = [
    pkgs.autoPatchelfHook
    pkgs.makeWrapper
  ];
  buildInputs = [
    pkgs.stdenv.cc.cc.lib
    pkgs.openssl
    pkgs.zlib
  ];
  patches = [
    ../browser-image/camoufox-structured-errors.patch
    ../browser-image/camoufox-workspaces.patch
    ../browser-image/camoufox-navigation.patch
    ../browser-image/camoufox-browser-surface.patch
  ];
  postPatch = ''
    cp ${./browser-deps/package.json} package.json
    cp ${./browser-deps/package-lock.json} package-lock.json
    cp ${../browser-image/workspace-lease.ts} src/workspace-lease.ts
    cp ${../browser-image/workspace-tools.ts} src/workspace-tools.ts
    cp ${../browser-image/navigation.ts} src/navigation.ts
    cp ${../browser-image/request-guard.ts} src/request-guard.ts
    cp ${../browser-image/session-view.ts} src/session-view.ts
    cp ${../browser-image/session-inspect.ts} src/session-inspect.ts
    cp ${../browser-image/collect.ts} src/collect.ts
    cp ${../browser-image/dialogs.ts} src/dialogs.ts
  '';
  preBuild = ''
    patch --batch --forward -p1 < ${../browser-image/camoufox-virtual-display.patch}
    substituteInPlace node_modules/camoufox-js/dist/pkgman.js \
      --replace-fail 'return path.join(os.homedir(), ".cache", appName);' 'return "${browser}/lib/camoufox";'
    substituteInPlace node_modules/camoufox-js/dist/addons.js \
      --replace-fail 'if (fs.existsSync(addonPath)) {' 'if (fs.existsSync(join(addonPath, "manifest.json"))) {'
    patch --batch --forward -p1 < ${../browser-image/supergateway-endpoint.patch}
    patch --batch --forward -p1 < ${../browser-image/supergateway-disconnect.patch}
    node ${../browser-image/virtual-display.test.mjs} node_modules/camoufox-js/dist/
    node ${../browser-image/gateway-disconnect.test.mjs} node_modules/supergateway/dist/index.js
  '';
  postBuild = ''
    node ${../browser-image/workspace-lease.test.mjs} dist/workspace-lease.js
    node ${../browser-image/navigation.test.mjs} dist/navigation.js
    node ${../browser-image/request-guard.test.mjs} dist/request-guard.js
    node ${../browser-image/workspace-close.test.mjs} dist/
  '';
  installPhase = ''
    runHook preInstall
    npm prune --omit=dev --ignore-scripts
    # npm installs both libc variants; NixOS uses only the GNU variant.
    rm -rf node_modules/impit-linux-*-musl
    mkdir -p $out/lib/max-browser $out/bin
    cp -r dist node_modules package.json $out/lib/max-browser/
    cp ${../scripts/test-browser-workspaces.mjs} $out/lib/max-browser/max-acceptance.mjs
    makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/max-browser \
      --add-flags "$out/lib/max-browser/node_modules/supergateway/dist/index.js" \
      --add-flags "--logLevel none --stateful --outputTransport streamableHttp --streamableHttpPath /mcp --port 0" \
      --add-flags "--stdio 'exec ${pkgs.nodejs_22}/bin/node $out/lib/max-browser/dist/index.js'" \
      --set FONTCONFIG_FILE ${fonts} \
      --set SSL_CERT_FILE ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
      --prefix PATH : ${
        lib.makeBinPath [
          pkgs.nodejs_22
          pkgs.xorg-server
          pkgs.xauth
          pkgs.which
          pkgs.coreutils
          pkgs.procps
        ]
      }
    makeWrapper ${pkgs.nodejs_22}/bin/node $out/bin/max-browser-workspace-test \
      --add-flags "$out/lib/max-browser/max-acceptance.mjs"
    runHook postInstall
  '';
  meta = {
    description = "Max's pinned native Camoufox MCP browser and HTTP gateway";
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "max-browser";
  };
}
