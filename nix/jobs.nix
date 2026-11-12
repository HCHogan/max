# What Max runs in a group's VM, as units of the guest's systemd: the
# slice they are in, the command that starts them and hears them end
# (max-jobs.sh), and the unit that tells Max of a background command's
# end. A module of its own, so that its test boots it without a VM's
# shares and command line. See "Lifetimes move to systemd" in
# docs/rust-rewrite.md.
{ config, pkgs, ... }:
let
  runner = import ./runner.nix { inherit pkgs; };
  jobs = import ./max-jobs.nix {
    inherit pkgs runner;
    systemd = config.systemd.package;
  };
in
{
  # On the PATH: a unit's hook runs the system's, whichever image started
  # the unit.
  environment.systemPackages = [ jobs ];

  # Calls, background commands and agents. No limits of its own: they are
  # the VM's work, which Max's own units (max-units.slice) yield to.
  systemd.slices.max-jobs = {
    description = "What Max runs: calls, background commands and agents";
  };

  # A background command's end, told to Max: `maxx wake`, tried again for
  # as long as max doesn't take it, as while it restarts. One that waits
  # is a unit still activating, so `systemctl list-units 'max-notify@*'`
  # lists what Max hasn't heard yet.
  systemd.services."max-notify@" = {
    description = "Tell Max that %i ended";
    # A switch to a new image leaves the ones that wait.
    restartIfChanged = false;
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${jobs}/bin/max-jobs notify %i";
      Restart = "on-failure";
      RestartSec = 2;
      RestartSteps = 5;
      RestartMaxDelaySec = 60;
    };
  };
}
