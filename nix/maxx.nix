# maxx: Max's tools in a group's VM, on the command line and for
# run_code's programs (maxx.js, runner.js, tools.js), and all there is of
# Max's own on the guest's PATH. The host's tools it calls through the
# host's service (client.js); the guest's own are in local.json: what
# Node does itself (shown.js, video.js), and `units apply`, which the
# guest's systemd does, a script here (max-units.sh). Beside the tools,
# and no tools themselves, are `maxx jobs` (max-jobs.sh): what max runs
# for a call and for a background command, and the hooks of their units;
# and `maxx connect` (connect.js), ssh's way into another conversation's
# VM.
# bin/maxx runs the scripts itself, and anything else goes to Node, which
# reads the options.
#
# Beside them is what max.browser() needs: playwright-core, which
# connects to the VM's Chromium (guest.nix) and has no dependencies of
# its own. tools.video runs the guest's ffmpeg, from the PATH. The guest
# links /run/max/runner.js here, and Node resolves the link, so the
# runner finds the rest next to it.
{
  pkgs,
  systemd,
}:
let
  inherit (pkgs) lib;
  playwright = pkgs.fetchurl {
    url = "https://registry.npmjs.org/playwright-core/-/playwright-core-1.59.0.tgz";
    hash = "sha512-PW/X/IoZ6BMUUy8rpwHEZ8Kc0IiLIkgKYGNFaMs5KmQhcfLILNx9yCQD0rnWeWfz1PNeqcFP1BsihQhDOBCwZw==";
  };
  # A notice calls maxx itself, for a wake: by the PATH, where bin/maxx
  # puts itself first.
  scripts = {
    jobs = pkgs.writeShellApplication {
      name = "maxx-jobs";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.gawk
        pkgs.gnused
        pkgs.jq
        pkgs.util-linux
        systemd
      ];
      text = builtins.readFile ./max-jobs.sh;
    };
    units = pkgs.writeShellApplication {
      name = "maxx-units";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.util-linux
        systemd
      ];
      text = builtins.readFile ./max-units.sh;
    };
  };
in
pkgs.runCommand "maxx" { meta.mainProgram = "maxx"; } ''
  mkdir -p $out/lib/max-runner/node_modules/playwright-core
  tar -xzf ${playwright} --strip-components=1 \
    -C $out/lib/max-runner/node_modules/playwright-core
  cp ${./runner.js} $out/lib/max-runner/runner.js
  cp ${./browser.js} $out/lib/max-runner/browser.js
  cp ${./client.js} $out/lib/max-runner/client.js
  cp ${./tools.js} $out/lib/max-runner/tools.js
  cp ${./local.json} $out/lib/max-runner/local.json
  cp ${./shown.js} $out/lib/max-runner/shown.js
  cp ${./video.js} $out/lib/max-runner/video.js
  cp ${./maxx.js} $out/lib/max-runner/maxx.js
  cp ${./connect.js} $out/lib/max-runner/connect.js
  mkdir -p $out/bin
  cat > $out/bin/maxx <<EOF
  #!${pkgs.runtimeShell}
  # What it runs calls it too.
  export PATH=$out/bin:\$PATH
  case "\''${1-} \''${2-}" in
    # max's own, and the units' hooks: no tools.
    "jobs "*)
      shift
      exec ${lib.getExe scripts.jobs} "\$@"
      ;;
    "connect "*)
      shift
      exec ${pkgs.nodejs}/bin/node $out/lib/max-runner/connect.js "\$@"
      ;;
    # Its words alone, or with a JSON object as a program writes one:
    # there are no options for Node to read.
    "units apply")
      if [ \$# -eq 2 ] || { [ \$# -eq 3 ] && [[ \$3 == "{"* ]]; }; then
        exec ${lib.getExe scripts.units} "\''${3-}"
      fi
      ;;
  esac
  exec ${pkgs.nodejs}/bin/node $out/lib/max-runner/maxx.js "\$@"
  EOF
  chmod +x $out/bin/maxx
''
