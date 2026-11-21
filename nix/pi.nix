# pi, as the guest has it: on the models max serves the VM, with what
# an agent of Max's is told of itself; see pi.sh.
{ pkgs, pi }:
pkgs.writeShellApplication {
  name = "pi";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.curl
    pkgs.diffutils
    pkgs.findutils
    pkgs.gnugrep
    pkgs.jq
  ];
  runtimeEnv = {
    PI_BIN = "${pi}/bin/pi";
    PI_SYSTEM = "${./pi-system.md}";
  };
  text = builtins.readFile ./pi.sh;
}
