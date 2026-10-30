# max-pi: pi for a background job, in the groups' VMs; see max-pi.sh.
{ pkgs, pi }:
pkgs.writeShellApplication {
  name = "max-pi";
  runtimeInputs = [
    pi
    pkgs.jq
  ];
  # ask_max, the agent's way to ask Max; see ask-max.ts.
  runtimeEnv.MAX_ASK_MAX = "${./ask-max.ts}";
  text = builtins.readFile ./max-pi.sh;
}
