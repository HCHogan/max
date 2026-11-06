# max-pi: pi for a background job, in the groups' VMs; see max-pi.sh.
{ pkgs, pi }:
pkgs.writeShellApplication {
  name = "max-pi";
  runtimeInputs = [
    pi
    pkgs.jq
  ];
  # ask_max, the agent's way to ask Max, and maxx's client, which it asks
  # with; see ask-max.ts.
  runtimeEnv = {
    MAX_ASK_MAX = "${./ask-max.ts}";
    MAX_CLIENT = "${./client.js}";
  };
  text = builtins.readFile ./max-pi.sh;
}
