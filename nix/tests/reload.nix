{
  nixpkgs,
  maxModule,
  system,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  fakeMax = pkgs.writeShellApplication {
    name = "max";
    runtimeInputs = [ pkgs.python3 ];
    text = ''exec python3 ${./fake-max.py} "$@"'';
  };
  fakeMaxctl = pkgs.writeShellApplication {
    name = "maxctl";
    runtimeInputs = [ pkgs.python3 ];
    text = ''exec python3 ${./fake-maxctl.py} "$@"'';
  };
  testPackage = pkgs.symlinkJoin {
    name = "max-reload-test-package";
    paths = [ fakeMax fakeMaxctl ];
  };
  replacementPackage = pkgs.runCommand "max-reload-test-package-v2" { } ''
    mkdir -p $out/bin
    cp -L ${testPackage}/bin/max $out/bin/max
    cp -L ${testPackage}/bin/maxctl $out/bin/maxctl
    chmod +x $out/bin/max $out/bin/maxctl
    echo v2 > $out/revision
  '';
in
pkgs.testers.runNixOSTest {
  name = "max-configuration-reload";

  nodes.machine =
    { lib, ... }:
    {
      imports = [ maxModule ];
      system.stateVersion = "26.05";

      services.max = {
        enable = true;
        package = testPackage;
        configFile = "/run/max-test-config.yaml";
        postgres.enable = false;
        sandboxImage.enable = false;
        browserImage.enable = false;
        maxops = {
          enable = true;
          tokenFile = "/run/maxops-test-token";
          allowedGroups = [ 611798505 ];
        };
      };

      # A package path change alters ExecStart/ExecReload and must use
      # systemd's restart path, never the configuration reload path.
      specialisation.package-change.configuration.services.max.package =
        lib.mkForce replacementPackage;

      virtualisation.docker.enable = lib.mkForce false;
      systemd.services.max.requires = lib.mkForce [ "max-test-config.service" ];
      systemd.services.max.after = lib.mkForce [ "max-test-config.service" ];
      systemd.services.max-test-config = {
        description = "prepare mutable Max reload fixture";
        wantedBy = [ "multi-user.target" ];
        before = [ "max.service" ];
        serviceConfig.Type = "oneshot";
        script = ''
          if [ ! -e /run/max-test-config.yaml ]; then
            echo 'persona: old' > /run/max-test-config.yaml
          fi
          umask 077
          printf '%s' 'maxops-nixos-fixture-token-0000001' > /run/maxops-test-token
        '';
      };
    };

  testScript = ''
    start_all()
    machine.wait_for_unit("max.service")
    machine.wait_for_file("/run/max/control.sock")
    machine.succeed("test -r /run/credentials/max.service/maxops-token")
    environment = machine.succeed("systemctl show max --property=Environment --value")
    assert "MAX_MAXOPS_ENABLED=True" in environment
    assert "MAX_MAXOPS_ALLOWED_GROUPS=611798505" in environment
    assert "MAX_MAXOPS_TOKEN_FILE=/run/credentials/max.service/maxops-token" in environment
    assert "maxops-nixos-fixture-token-0000001" not in environment

    original_pid = machine.succeed("systemctl show max -p MainPID --value").strip()
    replacement_system = machine.succeed("readlink -f /run/current-system/specialisation/package-change").strip()
    machine.succeed("printf 'persona: new\\n' > /run/max-test-config.yaml")
    machine.succeed("systemctl reload max")
    assert machine.succeed("systemctl show max -p MainPID --value").strip() == original_pid
    assert machine.succeed("cat /run/max/generation").strip() == "2"

    machine.succeed("printf 'invalid_reload: true\\n' > /run/max-test-config.yaml")
    machine.fail("systemctl reload max")
    assert machine.succeed("systemctl is-active max").strip() == "active"
    assert machine.succeed("systemctl show max -p MainPID --value").strip() == original_pid
    assert machine.succeed("cat /run/max/generation").strip() == "2"

    machine.succeed(f"{replacement_system}/bin/switch-to-configuration test")
    machine.wait_for_unit("max.service")
    replacement_pid = machine.succeed("systemctl show max -p MainPID --value").strip()
    assert replacement_pid != original_pid
  '';
}
