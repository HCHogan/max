# max-units: Max's own units, from /work/.max/systemd; see max-units.sh.
{ pkgs, systemd }:
pkgs.writeShellApplication {
  name = "max-units";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.gnugrep
    pkgs.util-linux
    systemd
  ];
  text = builtins.readFile ./max-units.sh;
}
