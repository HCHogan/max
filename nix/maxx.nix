# maxx: Max's tools in a group's VM, on the command line and for
# run_code's programs (maxx.js, runner.js, tools.js), and all there is of
# Max's own on the guest's PATH. The host's tools it calls through the
# host's service (client.js); the guest's own are in local.json: what
# Node does itself (shown.js, video.js), and what the guest's systemd
# does, each a script here that takes its arguments as a JSON object
# (max-jobs.sh, max-agent.sh, max-units.sh). bin/maxx runs those itself
# when it is given just that, which is how max calls and how the units'
# hooks do; anything else goes to Node, which reads the options and
# calls back.
#
# Beside them is what max.browser() needs: playwright-core, which
# connects to the VM's Chromium (guest.nix) and has no dependencies of
# its own. tools.video runs the guest's ffmpeg, from the PATH. The guest
# links /run/max/runner.js here, and Node resolves the link, so the
# runner finds the rest next to it.
{
  pkgs,
  systemd,
  pi,
}:
let
  inherit (pkgs) lib;
  playwright = pkgs.fetchurl {
    url = "https://registry.npmjs.org/playwright-core/-/playwright-core-1.59.0.tgz";
    hash = "sha512-PW/X/IoZ6BMUUy8rpwHEZ8Kc0IiLIkgKYGNFaMs5KmQhcfLILNx9yCQD0rnWeWfz1PNeqcFP1BsihQhDOBCwZw==";
  };
  # pi as one of Max's background agents: what an agent's unit runs.
  max-pi = import ./max-pi.nix { inherit pkgs pi; };
  # They call maxx themselves, for a wake and for an agent's unit: by the
  # PATH, where bin/maxx puts itself first.
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
    agent = pkgs.writeShellApplication {
      name = "maxx-agent";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.gnused
        pkgs.jq
        pkgs.util-linux
        systemd
        max-pi
      ];
      text = builtins.readFile ./max-agent.sh;
    };
    units = pkgs.writeShellApplication {
      name = "maxx-units";
      runtimeInputs = [
        pkgs.coreutils
        pkgs.curl
        pkgs.diffutils
        pkgs.gnugrep
        pkgs.jq
        pkgs.util-linux
        systemd
      ];
      text = builtins.readFile ./max-units.sh;
    };
  };
  # The guest's own that a script does, by their words: which script.
  local = builtins.fromJSON (builtins.readFile ./local.json);
  cases = lib.concatMapStrings (
    tool:
    assert builtins.length tool.words == 2;
    ''
      "${lib.concatStringsSep " " tool.words}") run=${lib.getExe scripts.${tool.run}} ;;
    ''
  ) (builtins.filter (tool: tool.run != "node") local);
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
  mkdir -p $out/bin
  cat > $out/bin/maxx <<EOF
  #!${pkgs.runtimeShell}
  # What it runs calls it too.
  export PATH=$out/bin:\$PATH
  run=""
  case "\''${1-} \''${2-}" in
    # The units' own, and an agent's unit: not tools.
    "units agent" | "units ended" | "units notify" | "units idle")
      shift
      exec ${lib.getExe scripts.jobs} "\$@"
      ;;
  ${cases}esac
  # One of the guest's own, its words and a JSON object: there are no
  # options to read.
  if [ -n "\$run" ] && [ \$# -eq 3 ] && [[ \$3 == \{* ]]; then
    exec "\$run" "\$2" "\$3"
  fi
  exec ${pkgs.nodejs}/bin/node $out/lib/max-runner/maxx.js "\$@"
  EOF
  chmod +x $out/bin/maxx
''
