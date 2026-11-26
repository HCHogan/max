# fx, as the guest has it: on the models max serves the VM, with what
# an agent of Max's is told of itself; see fx.sh.
{ pkgs, fx }:
pkgs.writeShellApplication {
  name = "fx";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.curl
    pkgs.diffutils
    pkgs.jq
  ];
  runtimeEnv = {
    FX_BIN = "${fx}/bin/fx";
    FX_SYSTEM = "${./fx-system.md}";
  };
  text = builtins.readFile ./fx.sh;
}
