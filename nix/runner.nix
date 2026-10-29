# run_code's runner, with what a browser in its SDK needs beside it:
# camoufox-js and playwright-core, at the versions the Haskell version ran,
# and camoufox itself. The guest links /run/max/runner.js here, and Node
# resolves the link, so the runner finds node_modules next to it.
{ pkgs }:
let
  camoufox = import ./camoufox.nix { inherit pkgs; };
in
pkgs.buildNpmPackage {
  pname = "max-runner";
  version = "0";
  src = ./browser-deps;
  npmDepsHash = "sha256-uEMatVZAaQyRq6uM09lMAJH8yAaJIQD5FW/AOm4pJwo=";
  # Nothing is compiled, better-sqlite3 included; see below.
  npmFlags = [ "--ignore-scripts" ];
  dontNpmBuild = true;
  # impit's prebuilt module, which camoufox-js loads.
  nativeBuildInputs = [ pkgs.autoPatchelfHook ];
  buildInputs = [ pkgs.stdenv.cc.cc.lib ];
  installPhase = ''
    runHook preInstall
    # camoufox-js looks for the browser in the user's cache, and would
    # download it there.
    substituteInPlace node_modules/camoufox-js/dist/pkgman.js \
      --replace-fail 'return path.join(os.homedir(), ".cache", appName);' 'return "${camoufox}/lib/camoufox";'
    # camoufox-js reads its WebGL fingerprints with better-sqlite3, a native
    # module; Node's own sqlite reads them as well.
    substituteInPlace node_modules/camoufox-js/dist/webgl/sample.js \
      --replace-fail 'const { default: BetterSqlite3 } = await import("better-sqlite3");' \
        'const { DatabaseSync: BetterSqlite3 } = await import("node:sqlite");'
    # npm installs both libc's variants; NixOS has glibc.
    rm -rf node_modules/impit-linux-*-musl
    mkdir -p $out/lib/max-runner
    cp -r node_modules $out/lib/max-runner/
    cp ${./runner.js} $out/lib/max-runner/runner.js
    runHook postInstall
  '';
}
