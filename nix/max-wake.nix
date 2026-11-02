# max-wake: wakes Max from a program in the VM; see max-wake.sh.
{ pkgs, runner }:
pkgs.writeShellApplication {
  name = "max-wake";
  runtimeInputs = [
    pkgs.jq
    runner
  ];
  text = builtins.readFile ./max-wake.sh;
}
