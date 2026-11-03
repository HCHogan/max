# run_code's runner and its SDK (runner.js, browser.js, client.js,
# video.js), with what max.browser() needs beside them: playwright-core,
# which connects to the VM's Chromium (guest.nix) and has no dependencies
# of its own. max.video runs the guest's ffmpeg, from the PATH. The
# guest links /run/max/runner.js here, and Node resolves the link, so the
# runner finds browser.js and node_modules next to it. bin/maxx is the
# same client on the command line (maxx.js).
{ pkgs }:
let
  playwright = pkgs.fetchurl {
    url = "https://registry.npmjs.org/playwright-core/-/playwright-core-1.59.0.tgz";
    hash = "sha512-PW/X/IoZ6BMUUy8rpwHEZ8Kc0IiLIkgKYGNFaMs5KmQhcfLILNx9yCQD0rnWeWfz1PNeqcFP1BsihQhDOBCwZw==";
  };
in
pkgs.runCommand "max-runner" { } ''
  mkdir -p $out/lib/max-runner/node_modules/playwright-core
  tar -xzf ${playwright} --strip-components=1 \
    -C $out/lib/max-runner/node_modules/playwright-core
  cp ${./runner.js} $out/lib/max-runner/runner.js
  cp ${./browser.js} $out/lib/max-runner/browser.js
  cp ${./client.js} $out/lib/max-runner/client.js
  cp ${./video.js} $out/lib/max-runner/video.js
  cp ${./maxx.js} $out/lib/max-runner/maxx.js
  mkdir -p $out/bin
  cat > $out/bin/maxx <<EOF
  #!${pkgs.runtimeShell}
  exec ${pkgs.nodejs}/bin/node $out/lib/max-runner/maxx.js "\$@"
  EOF
  chmod +x $out/bin/maxx
''
