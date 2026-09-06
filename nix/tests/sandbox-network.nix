{ nixpkgs, maxModule, system }:
let
  pkgs = nixpkgs.legacyPackages.${system};
  fakeMax = pkgs.writeShellScriptBin "max" "exec ${pkgs.coreutils}/bin/sleep infinity";
  image = pkgs.dockerTools.buildImage {
    name = "max-network-test";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "max-network-test-root";
      paths = [ pkgs.busybox pkgs.curl ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/sleep" "infinity" ];
  };
in
pkgs.testers.runNixOSTest {
  name = "max-sandbox-network";
  nodes.machine = { ... }: {
    imports = [ maxModule ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = 2048;
    virtualisation.diskSize = 4096;
    environment.systemPackages = [ pkgs.python3 pkgs.iproute2 pkgs.curl ];
    services.max = {
      enable = true;
      package = fakeMax;
      postgres.enable = false;
      sandboxImage.enable = false;
      browserImage.enable = false;
    };
    # The fixture endpoints live in a separate routed namespace, so denial
    # checks exercise forwarding rather than merely an absent destination.
    networking.firewall.enable = false;
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("max.service")
    machine.wait_for_unit("max-sandbox-network.service")
    machine.succeed("docker load < ${image}")
    machine.succeed("ip netns add outside")
    machine.succeed("ip link add uplink type veth peer name external")
    machine.succeed("ip link set external netns outside")
    machine.succeed("ip addr add 1.1.1.1/30 dev uplink; ip link set uplink up")
    machine.succeed("ip netns exec outside ip addr add 1.1.1.2/30 dev external")
    machine.succeed("ip netns exec outside ip link set external up; ip netns exec outside ip link set lo up")
    machine.succeed("ip netns exec outside ip route add default via 1.1.1.1")
    destinations = ["8.8.8.8", "10.10.10.10", "100.64.0.2", "169.254.169.254"]
    for address in destinations:
        machine.succeed(f"ip netns exec outside ip addr add {address}/32 dev lo")
        machine.succeed(f"ip route add {address}/32 via 1.1.1.2")
    machine.succeed("mkdir -p /tmp/public-fixture; echo public-ok > /tmp/public-fixture/index.html")
    machine.succeed("ip netns exec outside python3 -m http.server 8080 --directory /tmp/public-fixture >/tmp/public-http.log 2>&1 &")
    for address in destinations:
        machine.wait_until_succeeds(f"curl -fsS --max-time 3 http://{address}:8080/ | grep public-ok")
    machine.succeed("docker run -d --name sandbox --network max-sandbox --user 1000:1000 --cap-drop ALL --read-only max-network-test")
    curl = "docker exec sandbox curl -fsS --connect-timeout 2 --max-time 3 "

    with subtest("public requests work and address-based restrictions survive DNS rebinding"):
        machine.succeed(curl + "http://8.8.8.8:8080/ | grep public-ok")
        machine.succeed(curl + "--resolve download.test:8080:8.8.8.8 http://download.test:8080/ | grep public-ok")
        for address in destinations[1:]:
            machine.fail(curl + f"http://{address}:8080/")
            machine.fail(curl + f"--resolve download.test:8080:{address} http://download.test:8080/")

    with subtest("host, peer sandboxes and Docker DNAT remain blocked"):
        machine.succeed("ip addr add 9.9.9.9/32 dev lo")
        machine.succeed("python3 -m http.server 8081 --directory /tmp/public-fixture >/tmp/host-http.log 2>&1 &")
        machine.wait_until_succeeds("curl -fsS --max-time 3 http://9.9.9.9:8081/ | grep public-ok", timeout=60)
        gateway = machine.succeed("docker network inspect max-sandbox --format '{{(index .IPAM.Config 0).Gateway}}'").strip()
        machine.fail(curl + f"http://{gateway}:8081/")
        machine.fail(curl + "http://9.9.9.9:8081/")
        machine.succeed("docker run -d --name peer --network max-sandbox -p 9.9.9.9:18080:8080 max-network-test /bin/sh -c 'mkdir -p /tmp/www; echo peer-ok > /tmp/www/index.html; exec /bin/httpd -f -p 8080 -h /tmp/www'")
        peer = machine.succeed("docker inspect peer --format '{{(index .NetworkSettings.Networks \"max-sandbox\").IPAddress}}'").strip()
        machine.wait_until_succeeds("curl -fsS --max-time 3 http://9.9.9.9:18080/ | grep peer-ok", timeout=60)
        machine.fail(curl + f"http://{peer}:8080/")
        machine.fail(curl + "http://9.9.9.9:18080/")

    with subtest("atomic firewall reload and repeated provisioning preserve the policy"):
        machine.succeed("systemctl reload nftables; systemctl restart max-sandbox-network")
        machine.succeed(curl + "http://8.8.8.8:8080/ | grep public-ok")
        machine.fail(curl + "http://10.10.10.10:8080/")
        assert machine.succeed("docker network inspect max-sandbox --format '{{.EnableIPv6}}'").strip() == "false"
  '';
}
