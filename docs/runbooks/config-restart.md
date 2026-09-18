# Configuration changes

Max reads and validates configuration once at startup. Apply changes with:

```console
sudo systemctl restart max
systemctl is-active max
journalctl -u max -o cat --since -5m
```

Shutdown stops admitting agent turns, allows a bounded drain, then terminates
remaining workers. Restart reconnects platform clients, including the NapCat
reverse WebSocket. There is no hot-reload socket or `maxctl` command.

The NixOS module uses `/etc/max/config.yaml` and puts the effective configuration
in `restartTriggers`. Activating changed `services.max.settings` restarts Max;
package and unit changes also use normal systemd restart behavior.

For a hand-managed mutable `services.max.configFile`, editing its contents does
not change a Nix store hash. Restart Max explicitly after editing it or rotating
secrets in an `EnvironmentFile`. Invalid configuration prevents startup; restore
the previous configuration and restart to recover.

The `nixos-restart` VM fixture verifies that changing only the configured
persona replaces the PID and loads the new value, and that the unit has no
`ExecReload` action.
