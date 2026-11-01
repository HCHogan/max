# max-wake: wakes Max from a program in the VM; see max-wake.sh.
{ pkgs }:
pkgs.writeShellApplication {
  name = "max-wake";
  runtimeInputs = [
    pkgs.jq
    pkgs.socat
  ];
  text = builtins.readFile ./max-wake.sh;
}
