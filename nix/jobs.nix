# What Max runs in a group's VM, as units of the guest's systemd: the
# slice they are in, the command that starts them and hears them end
# (maxx, whose `jobs` are max-jobs.sh), and the unit that tells Max of a
# background command's end. A module of its own, so that its test boots
# it without a VM's shares and command line. See "Background commands"
# in docs/design/jobs.md.
{
  config,
  pkgs,
  ...
}:
let
  maxx = import ./maxx.nix {
    inherit pkgs;
    systemd = config.systemd.package;
  };
in
{
  # On the PATH, where max, Max and a unit's hook find it.
  environment.systemPackages = [ maxx ];

  # Calls and background commands, background agents among them. No
  # limits of its own: they are the VM's work, which Max's own units
  # (max-units.slice) yield to.
  systemd.slices.max-jobs = {
    description = "What Max runs: calls and background commands";
  };

  # The caches of a guest that has had nothing of Max's to do for ten
  # minutes, dropped then and every ten minutes for as long as that
  # lasts: its page cache and the files it remembers, which the store's
  # virtiofsd keeps open on the host, are otherwise never freed while it
  # is up, and what it frees goes back to the host through the balloon's
  # free page reporting. Not between two calls of a turn, when the next
  # reads what the last one did (2026-11-13; for a day it asked only that
  # nothing ran at that moment). max asked for this over SSH until the
  # VMs came to outlive it.
  systemd.timers.max-trim = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "10min";
      OnUnitActiveSec = "10min";
    };
  };
  systemd.services.max-trim = {
    description = "Drop the caches of a guest with nothing of Max's to do";
    path = [ maxx ];
    script = ''
      maxx jobs idle 600 || exit 0
      sync
      echo 3 > /proc/sys/vm/drop_caches
      echo 1 > /proc/sys/vm/compact_memory
    '';
    serviceConfig.Type = "oneshot";
  };

  # A background command's end, told to Max: `maxx wake`, tried again for
  # as long as max doesn't take it, as while it restarts. One that waits
  # is a unit still activating, so `systemctl list-units 'max-notify@*'`
  # lists what Max hasn't heard yet.
  systemd.services."max-notify@" = {
    description = "Tell Max that %i ended";
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${maxx}/bin/maxx jobs notify %i";
      Restart = "on-failure";
      RestartSec = 2;
      RestartSteps = 5;
      RestartMaxDelaySec = 60;
    };
  };
}
