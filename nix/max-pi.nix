# max-pi: pi for a background job, in the groups' VMs; see max-pi.sh.
{ pkgs, pi }:
pkgs.writeShellApplication {
  name = "max-pi";
  runtimeInputs = [
    pi
    pkgs.jq
  ];
  text = builtins.readFile ./max-pi.sh;
}
