# max-jobs: Max's calls and background commands, as units; see max-jobs.sh.
{
  pkgs,
  systemd,
  runner,
}:
pkgs.writeShellApplication {
  name = "max-jobs";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gawk
    pkgs.jq
    pkgs.util-linux
    systemd
    # maxx, for the notice.
    runner
  ];
  text = builtins.readFile ./max-jobs.sh;
}
