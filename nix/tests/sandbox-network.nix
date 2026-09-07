{
  nixpkgs,
  maxModule,
  maxPackage,
  system,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  migrationDocker = pkgs.writeShellScriptBin "docker" ''
    set -eu
    case "$1 $2" in
      'info --format') echo /var/tmp/migration-legacy ;;
      'volume ls') echo max-sb-300-s1-data ;;
      'volume inspect')
        printf '[{"Driver":"local","Options":{},"Mountpoint":"/var/tmp/migration-legacy/volumes/%s/_data"}]\n' "$3"
        ;;
      'ps --format') ;;
      *) exit 64 ;;
    esac
  '';
  testPackage = pkgs.runCommand "max-native-test-client" { } ''
    mkdir -p $out/bin
    ln -s ${maxPackage}/bin/max-runtime $out/bin/max-runtime
    ln -s ${maxPackage}/bin/maxctl $out/bin/maxctl
    cat > $out/bin/max <<'SCRIPT'
    #!${pkgs.runtimeShell}
    exec ${pkgs.coreutils}/bin/sleep infinity
    SCRIPT
    chmod +x $out/bin/max
  '';
in
pkgs.testers.runNixOSTest {
  name = "max-native-runtime";
  requiredFeatures.kvm = false;
  globalTimeout = 1800;
  nodes.machine = { config, lib, ... }: {
    imports = [ maxModule ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 8192;
    virtualisation.cores = 2;
    environment.systemPackages = [
      pkgs.python3
      pkgs.iproute2
      pkgs.curl
      pkgs.jq
      pkgs.hello
      pkgs.rsync
      pkgs.dnsmasq
      config.services.max.browser.package
    ];
    users.users.max-napcat = { isSystemUser = true; group = "max-napcat"; };
    users.groups.max-napcat = { };
    services.max = {
      enable = true;
      package = testPackage;
      postgres.enable = false;
      sandbox.nameservers = [ "8.8.8.8" ];
    };
    systemd.services."max-browser@".environment = {
      NODE_ENV = "test";
      CAMOUFOX_MCP_TEST_ALLOW_LOCALHOST = "1";
      CAMOUFOX_MCP_TEST_ALLOWED_LOCALHOST_PORTS = "18765";
    };
    specialisation.browser-template.configuration.systemd.services."max-browser@".serviceConfig.CPUQuota =
      lib.mkForce "150%";
    # The fixture destinations are real listeners behind a routed namespace.
    networking.firewall.enable = false;
  };
  testScript = ''
    import shlex
    start_all()
    machine.wait_for_unit("max.service")
    machine.wait_for_unit("max-sandbox-network.service")
    cli = "runuser -u max-bot -- max-runtime "
    name = "max-sb--100-s1"
    unit = "max-sandbox@-100-s1.service"
    volume = name + "-data"
    create = f"create {name} nixos-sandbox-v1 {volume} max-sandbox"
    execute = cli + f"exec {name} "
    try:
        machine.succeed(cli + create, timeout=150)
    except Exception:
        print(machine.succeed("journalctl -u max-runtime -u 'max-sandbox@*' --no-pager -n 120"))
        raise
    machine.succeed("machinectl show max-sandbox--100-s1 -p Leader | grep -E 'Leader=[1-9]'")
    try:
        assert machine.succeed(execute + "id -u").strip() == "1000"
    except Exception:
        print(machine.succeed("journalctl --machine=max-sandbox--100-s1 --no-pager -n 80"))
        raise
    assert machine.succeed(cli + f"policy {name}").strip() == "6 max-sandbox 1"

    with subtest("store, host paths and namespaces are protected"):
        machine.fail(execute + "touch /nix/store/max-test-write")
        machine.fail(execute + "cat /etc/shadow")
        machine.fail(execute + "unshare -m true")
        machine.succeed(execute + "test ! -S /nix/var/nix/daemon-socket/socket")
        machine.succeed(execute + "sh -c 'findmnt -no OPTIONS /nix/store | grep -w ro'")
        machine.succeed(execute + "sh -c 'echo durable > /work/keep; git --version; python3 --version; jq --version'")
        machine.succeed("systemd-run --quiet --pipe --wait --collect --uid=max-bot -p PrivateUsers=yes -p NoNewPrivileges=yes -p RestrictNamespaces=yes max-runtime status " + name)
        machine.succeed("chmod 666 /run/max-runtime/control.sock")
        status, _ = machine.execute("runuser -u nobody -- max-runtime list max-sb-")
        # Early credential rejection can close the socket while the client is
        # still sending descriptors, yielding transport-unavailable instead.
        assert status in (77, 125)
        machine.succeed("chmod 600 /run/max-runtime/control.sock")
        machine.fail(cli + "create ../../etc nixos-sandbox-v1 ../../etc-data max-sandbox")

    with subtest("client disconnect cancels the guest unit"):
        machine.fail("timeout 1 " + execute + "sh -c 'sleep 5; touch /work/cancel-failed'")
        machine.sleep(6)
        machine.succeed(execute + "test ! -e /work/cancel-failed")

    with subtest("pinned packages have explicit roots until sandbox destruction"):
        package = machine.succeed(cli + f"build {name} 120 hello").strip()
        assert package.startswith("/nix/store/")
        machine.succeed(execute + shlex.quote(package + "/bin/hello") + " | grep Hello")
        machine.succeed(f"find /nix/var/nix/gcroots/max-sandboxes/{name} -type l | grep .")

    with subtest("changing only the browser template preserves sandbox adoption"):
        invocation = machine.succeed(f"systemctl show {unit} -p InvocationID --value").strip()
        machine.succeed("/run/current-system/specialisation/browser-template/bin/switch-to-configuration test")
        assert machine.succeed(f"systemctl show {unit} -p InvocationID --value").strip() == invocation
        assert machine.succeed(cli + f"policy {name}").strip() == "6 max-sandbox 1"

    with subtest("Max restart preserves the sibling sandbox; manual replacement fails adoption"):
        invocation = machine.succeed(f"systemctl show {unit} -p InvocationID --value").strip()
        machine.succeed("systemctl restart max.service")
        assert machine.succeed(f"systemctl show {unit} -p InvocationID --value").strip() == invocation
        machine.succeed(f"systemctl restart {unit}")
        assert machine.succeed(cli + f"policy {name}").strip().startswith("old ")
        machine.succeed(cli + create)
        assert machine.succeed(execute + "cat /work/keep").strip() == "durable"

    machine.succeed("ip netns add outside")
    machine.succeed("ip link add uplink type veth peer name external")
    machine.succeed("ip link set external netns outside")
    machine.succeed("ip addr add 1.1.1.1/30 dev uplink; ip link set uplink up")
    machine.succeed("ip -n outside addr add 1.1.1.2/30 dev external")
    machine.succeed("ip -n outside link set external up; ip -n outside link set lo up")
    machine.succeed("ip -n outside route add default via 1.1.1.1")
    destinations = ["8.8.8.8", "10.10.10.10", "100.64.0.2", "169.254.169.254"]
    for address in destinations:
        machine.succeed(f"ip -n outside addr add {address}/32 dev lo")
        machine.succeed(f"ip route add {address}/32 via 1.1.1.2")
    machine.succeed("mkdir -p /tmp/public-fixture; echo public-ok > /tmp/public-fixture/index.html")
    machine.succeed("ip netns exec outside python3 -m http.server 8080 --directory /tmp/public-fixture >/tmp/public-http.log 2>&1 &")
    machine.succeed("ip netns exec outside dnsmasq --keep-in-foreground --no-resolv --no-hosts --bind-interfaces --listen-address=8.8.8.8 --address=/public.test/8.8.8.8 >/tmp/public-dns.log 2>&1 &")
    for address in destinations:
        machine.wait_until_succeeds(f"curl -fsS --max-time 3 http://{address}:8080/ | grep public-ok")
    curl = execute + "curl -fsS --connect-timeout 2 --max-time 3 "

    with subtest("public access works; private destinations and DNS rebinding are blocked"):
        machine.succeed(execute + "grep -Fx 'nameserver 8.8.8.8' /etc/resolv.conf")
        machine.wait_until_succeeds(curl + "http://public.test:8080/ | grep public-ok")
        machine.succeed(curl + "http://8.8.8.8:8080/ | grep public-ok")
        for address in destinations[1:]:
            machine.fail(curl + f"http://{address}:8080/")
            machine.fail(curl + f"--resolve download.test:8080:{address} http://download.test:8080/")
        machine.succeed("ip addr add 9.9.9.9/32 dev lo")
        machine.succeed("python3 -m http.server 8081 --directory /tmp/public-fixture >/tmp/host-http.log 2>&1 &")
        machine.wait_until_succeeds("curl -fsS --max-time 3 http://9.9.9.9:8081/ | grep public-ok")
        machine.fail(curl + "http://10.231.0.1:8081/")
        machine.fail(curl + "http://9.9.9.9:8081/")
        peer = "max-sb--100-s2"
        machine.succeed(cli + f"create {peer} nixos-sandbox-v1 {peer}-data max-sandbox")
        machine.succeed(cli + f"exec {peer} python3 -m http.server 8080 --directory /work >/tmp/peer-http.log 2>&1 &")
        peer_ip = machine.succeed(f"jq -r .address /var/lib/max-runtime/instances/{peer}.json").strip()
        machine.wait_until_succeeds(f"curl -fsS --max-time 3 http://{peer_ip}:8080/")
        machine.fail(curl + f"http://{peer_ip}:8080/")
        machine.succeed("systemctl reload nftables; systemctl restart max-sandbox-network")
        # Restarting the required network unit restarts its dependents. Wait
        # for the guest readiness notifications before exercising their buses.
        machine.wait_for_unit(unit)
        machine.wait_for_unit("max-sandbox@-100-s2.service")
        machine.succeed(curl + "http://8.8.8.8:8080/ | grep public-ok")
        machine.fail(curl + "http://10.10.10.10:8080/")

    with subtest("native browser workspaces retain lease and cleanup semantics"):
        machine.succeed(cli + "browser-create max-br--100")
        port = machine.succeed(cli + "browser-port max-br--100").strip()
        machine.succeed(f"MAX_BROWSER_ENDPOINT=http://127.0.0.1:{port}/mcp max-browser-workspace-test", timeout=300)
        machine.succeed("systemctl is-active --quiet max-browser@-100.service")
        machine.fail("journalctl -u max-browser@-100 --no-pager | grep -F 'Main process exited'")
        machine.fail("journalctl -u max-browser@-100 --no-pager | grep -E 'fixture_auth|fixture_identity|workspace-one'")
        machine.succeed(cli + "remove max-br--100")
        assert machine.succeed("systemctl show max-browser@-100 -p MainPID --value").strip() == "0"

    with subtest("stop preserves data; explicit destroy removes data and package roots"):
        machine.succeed("mkdir /var/lib/max-runtime/volumes/.migration-fixture")
        volumes = machine.succeed(cli + "volumes max-sb-").splitlines()
        assert volume in volumes and ".migration-fixture" not in volumes
        machine.fail(cli + f"volume-remove {volume}")
        machine.succeed("systemctl stop max-stack.target")
        # PartOf propagates stop jobs; the target's own stop job can finish
        # before a guest has completed its graceful shutdown.
        machine.wait_until_succeeds(f"test $(systemctl show {unit} -p MainPID --value) = 0")
        machine.wait_until_succeeds("test $(systemctl show max-sandbox@-100-s2.service -p MainPID --value) = 0")
        machine.succeed("systemctl start max-stack.target")
        machine.succeed(cli + create)
        assert machine.succeed(execute + "cat /work/keep").strip() == "durable"
        machine.succeed(cli + f"remove {name}")
        machine.succeed(cli + f"volume-status {volume}")
        machine.succeed(cli + f"volume-remove {volume}")
        machine.succeed(f"test ! -e /nix/var/nix/gcroots/max-sandboxes/{name}")
        status, _ = machine.execute(cli + f"volume-status {volume}")
        assert status == 3

    with subtest("unmigrated Docker volumes are unavailable, never falsely missing"):
        machine.succeed("mkdir -p /var/lib/docker/volumes/max-sb-200-s1-data/_data")
        status, _ = machine.execute(cli + "volume-status max-sb-200-s1-data")
        assert status == 125
        machine.fail(cli + "create max-sb-200-s1 nixos-sandbox-v1 max-sb-200-s1-data max-sandbox")

    with subtest("migration startup gates survive NixOS activation"):
        gated = ["max.service", "max-runtime.service", "max-runtime.socket"]
        for service in gated:
            dropin = f"/run/systemd/system/{service}.d/90-max-native-cutover.conf"
            machine.succeed(f"mkdir -p /run/systemd/system/{service}.d")
            machine.succeed(f"printf '[Unit]\\nConditionPathExists=/run/max-native-cutover-ready\\n' > {dropin}")
        machine.succeed("systemctl daemon-reload; systemctl stop " + " ".join(gated))
        machine.succeed("/run/current-system/bin/switch-to-configuration test")
        for service in gated:
            machine.succeed(f"systemctl start {service}")
            machine.fail(f"systemctl is-active {service}")
            machine.succeed(f"rm /run/systemd/system/{service}.d/90-max-native-cutover.conf")
        machine.succeed("systemctl daemon-reload; systemctl restart max-stack.target")
        machine.wait_for_unit("max.service")

    with subtest("offline migration verifies copies and preserves rollback data"):
        # Only Docker discovery is stubbed. Copying, systemd stop checks,
        # ownership, checksums and backups use the real migration script.
        source = "/var/tmp/migration-legacy/volumes/max-sb-300-s1-data/_data/.max-work"
        destination = "/var/tmp/migration-native/volumes/max-sb-300-s1-data/work"
        migrate = "PATH=${migrationDocker}/bin:$PATH MAX_RUNTIME_STATE_DIRECTORY=/var/tmp/migration-native bash ${../../scripts/migrate-native-runtime.sh}"
        machine.succeed(f"mkdir -p {source} /var/lib/max-bot/napcat/QQ /var/lib/max-bot/napcat/config /var/tmp/migration-legacy/volumes/max-nix/_data")
        machine.succeed(f"printf original > {source}/data; ln {source}/data {source}/hardlink; ln -s data {source}/symlink; printf hidden > {source}/.hidden")
        machine.succeed("printf fixture-account > /var/lib/max-bot/napcat/QQ/fixture; printf legacy-cache > /var/tmp/migration-legacy/volumes/max-nix/_data/keep")
        machine.succeed(migrate + " --check")
        machine.fail(migrate + " --copy")
        machine.succeed("systemctl stop max-stack.target max-runtime.service max-runtime.socket")
        machine.wait_until_succeeds("test -z \"$(systemctl list-units --all --plain --no-legend --state=active,activating,deactivating 'max-sandbox@*.service' 'max-browser@*.service')\"")
        machine.succeed(migrate + " --copy")
        machine.succeed(f"cmp {source}/data {destination}/data; cmp {source}/.hidden {destination}/.hidden")
        assert machine.succeed(f"readlink {destination}/symlink").strip() == "data"
        assert machine.succeed(f"stat -c '%u:%g:%a' {destination}").strip() == "1000:1000:700"
        assert machine.succeed(f"stat -c %i {destination}/data").strip() == machine.succeed(f"stat -c %i {destination}/hardlink").strip()
        machine.succeed(f"printf native-work > {destination}/new")
        machine.succeed(migrate + " --copy")
        assert machine.succeed(f"cat {destination}/new").strip() == "native-work"
        assert machine.succeed("cat /var/tmp/migration-legacy/volumes/max-nix/_data/keep").strip() == "legacy-cache"
        backups = machine.succeed("find /var/tmp/migration-native/migration-backups -name 'napcat-*.tar'").splitlines()
        assert len(backups) == 2
        for backup in backups:
            assert machine.succeed(f"tar -xOf {shlex.quote(backup)} ./QQ/fixture").strip() == "fixture-account"
        machine.succeed(f"cmp {source}/data {destination}/data")
  '';
}
