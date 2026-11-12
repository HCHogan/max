# max-agent: Max's background agents, as units; see max-agent.sh.
{
  pkgs,
  systemd,
  runner,
  jobs,
  pi,
}:
pkgs.writeShellApplication {
  name = "max-agent";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.curl
    pkgs.gnused
    pkgs.jq
    pkgs.util-linux
    systemd
    # max-jobs, which starts the unit; max-pi, which it runs; and maxx,
    # for an agent's question.
    jobs
    pi
    runner
  ];
  text = builtins.readFile ./max-agent.sh;
}
