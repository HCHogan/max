{ nixpkgs, maxModule, system }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  fakeMax = pkgs.writeShellApplication {
    name = "max";
    runtimeInputs = [ pkgs.python3 ];
    text = ''exec python3 ${./fake-max.py} "$@"'';
  };
in
pkgs.testers.runNixOSTest {
  name = "max-configuration-restart";
  requiredFeatures.kvm = false;
  nodes.machine = { lib, ... }: {
    imports = [ maxModule ];
    system.stateVersion = "26.05";
    services.max = {
      enable = true;
      package = fakeMax;
      settings.persona = "old";
      postgres.enable = false;
      sandbox.enable = false;
      sandboxNetwork.enable = false;
      browser.enable = false;
    };
    specialisation.config-change.configuration.services.max.settings.persona = lib.mkForce "new";
    virtualisation.docker.enable = lib.mkForce false;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("max.service")
    machine.wait_until_succeeds("test $(cat /run/max/persona) = old")
    original_pid = machine.succeed("systemctl show max -p MainPID --value").strip()
    assert machine.succeed("systemctl show max -p ExecReload --value").strip() == ""
    machine.fail("systemctl reload max")
    replacement = machine.succeed("readlink -f /run/current-system/specialisation/config-change").strip()
    machine.succeed(f"{replacement}/bin/switch-to-configuration test")
    machine.wait_for_unit("max.service")
    machine.wait_until_succeeds("test $(cat /run/max/persona) = new")
    assert machine.succeed("systemctl show max -p MainPID --value").strip() != original_pid
  '';
}
