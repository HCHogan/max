# max-pi: pi as one of Max's background agents, in the groups' VMs; see
# max-pi.sh.
{ pkgs, pi }:
pkgs.writeShellApplication {
  name = "max-pi";
  runtimeInputs = [
    pi
    pkgs.coreutils
    pkgs.gnused
    pkgs.jq
  ];
  # pi's plugin, which keeps the agent's side (max-agent.ts), and what the
  # agent is told of itself.
  runtimeEnv = {
    MAX_AGENT_PLUGIN = "${./max-agent.ts}";
    MAX_AGENT_SYSTEM = "${./agent-system.md}";
  };
  text = builtins.readFile ./max-pi.sh;
}
