{
  nixpkgs,
  maxModule,
  maxPackage,
  system,
}:
let
  pkgs = nixpkgs.legacyPackages.${system};
  tlsCert = pkgs.runCommand "max-operations-test-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir -p $out
    openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -out $out/cert.pem -keyout $out/key.pem \
      -subj '/CN=control' -addext 'subjectAltName=DNS:control'
  '';
  testPackage = pkgs.runCommand "max-operations-test-client" { } ''
    mkdir -p $out/bin
    ln -s ${maxPackage}/bin/max-runtime $out/bin/max-runtime
    printf '#!${pkgs.runtimeShell}\nexec ${pkgs.coreutils}/bin/sleep infinity\n' > $out/bin/max
    chmod +x $out/bin/max
  '';
in
pkgs.testers.runNixOSTest {
  name = "max-ssh-operations";
  globalTimeout = 1500;
  nodes.control = { config, ... }: {
    system.stateVersion = "26.05";
    virtualisation.memorySize = 1536;
    networking.firewall.enable = false;
    security.pki.certificateFiles = [ "${tlsCert}/cert.pem" ];
    services.headscale = {
      enable = true;
      address = "0.0.0.0";
      settings = {
        server_url = "https://control:8080";
        tls_cert_path = "${tlsCert}/cert.pem";
        tls_key_path = "${tlsCert}/key.pem";
        dns = {
          magic_dns = true;
          base_domain = "fleet.test";
          nameservers.global = [ "1.1.1.1" ];
        };
        derp.urls = [ ];
        derp.server = {
          enabled = true;
          region_id = 999;
          region_code = "test";
          region_name = "test";
          stun_listen_addr = "0.0.0.0:3478";
          ipv4 = "192.168.1.1";
        };
        policy.path = "/var/lib/headscale/policy.json";
      };
    };
    systemd.services.headscale.preStart = ''
      test -f /var/lib/headscale/policy.json || echo '{"groups":{"group:imdomestic":["max@example.com"]},"acls":[{"action":"accept","src":["group:imdomestic"],"dst":["group:imdomestic:*","10.66.0.1:*"]}],"ssh":[{"action":"accept","src":["group:imdomestic"],"dst":["autogroup:member"],"users":["max"]}]}' > /var/lib/headscale/policy.json
    '';
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "server";
      disableUpstreamLogging = true;
    };
    systemd.services.route-probe = {
      preStart = "${pkgs.iproute2}/bin/ip address replace 10.66.0.1/32 dev lo";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python -m http.server 8090 --bind 10.66.0.1 --directory ${pkgs.writeTextDir "probe" "route-ok"}";
    };
    users.users.max = {
      isNormalUser = true;
      hashedPassword = "!";
    };
    security.sudo.extraRules = [
      {
        users = [ "max" ];
        commands = [
          {
            command = "ALL";
            options = [ "NOPASSWD" ];
          }
        ];
      }
    ];
    environment.systemPackages = [ pkgs.jq ];
  };
  nodes.machine = { config, lib, ... }: {
    imports = [ maxModule ];
    system.stateVersion = "26.05";
    virtualisation.memorySize = 3072;
    virtualisation.cores = 2;
    networking.firewall.enable = false;
    security.pki.certificateFiles = [ "${tlsCert}/cert.pem" ];
    services.tailscale = {
      enable = true;
      disableUpstreamLogging = true;
    };
    systemd.services.max-ops-tailscaled.environment.TS_NO_LOGS_NO_SUPPORT = "1";
    services.max = {
      enable = true;
      package = testPackage;
      browser.enable = false;
      postgres.enable = false;
      operations = {
        enable = true;
        allowedGroups = [
          123
          456
        ];
        loginServer = "https://control:8080";
        domain = "fleet.test";
        authKeyFile = "/run/ops-preauthkey";
      };
    };
    environment.systemPackages = [
      pkgs.jq
      pkgs.curl
    ];
    specialisation.revoked.configuration.services.max.operations.allowedGroups = lib.mkForce [ 456 ];
  };
  testScript = ''
    import json, shlex
    start_all()
    control.wait_for_unit("headscale.service")
    control.wait_for_unit("route-probe.service")
    control.succeed("${pkgs.curl}/bin/curl -fsS --max-time 5 http://10.66.0.1:8090/probe | grep route-ok")
    machine.wait_for_unit("max.service")
    user = json.loads(control.succeed("headscale users create max@example.com -o json"))["id"]
    def key():
        return json.loads(control.succeed(f"headscale preauthkeys create -u {user} --reusable -o json"))["key"]
    control.succeed("tailscale up --login-server=https://control:8080 --hostname=fleet --ssh --advertise-routes=10.66.0.1/32 --accept-dns=false --auth-key=" + shlex.quote(key()), timeout=60)
    fleet_node = next(n["id"] for n in json.loads(control.succeed("headscale nodes list -o json")) if n["given_name"] == "fleet")
    control.succeed(f"headscale nodes approve-routes -i {fleet_node} -r 10.66.0.1/32")
    machine.succeed("tailscale up --login-server=https://control:8080 --hostname=host --accept-dns=false --auth-key=" + shlex.quote(key()), timeout=60)
    machine.succeed("printf %s " + shlex.quote(key()) + " > /run/ops-preauthkey; chmod 600 /run/ops-preauthkey")
    machine.succeed("systemctl reset-failed max-ops-tailscaled; systemctl start max-ops-tailscaled", timeout=90)
    cli = "runuser -u max-service -- max-runtime "
    first, second = "max-sb-123-s1", "max-sb-456-s2"
    def create(name, network):
        machine.succeed(cli + f"create {name} nixos-sandbox-v1 {name}-data {network}", timeout=180)
    def execute(name, command):
        return cli + f"exec {name} sh -c " + shlex.quote(command)
    assert machine.succeed(cli + "network 123").strip() == "maxops"
    assert machine.succeed(cli + "network 789").strip() == "max-sandbox"
    create(first, "maxops")
    create(second, "maxops")
    machine.fail(cli + "create max-sb-789-s3 nixos-sandbox-v1 max-sb-789-s3-data maxops")
    machine.succeed(execute(first, "echo durable > /work/keep"))
    machine.wait_until_succeeds(execute(first, "ssh fleet 'sudo -n id -u' | grep -x 0"), timeout=120)
    machine.wait_until_succeeds(execute(first, "curl -fsS --max-time 10 http://10.66.0.1:8090/probe | grep route-ok"), timeout=90)
    assert machine.succeed(cli + f"policy {first}").strip() == "7 maxops 1"
    machine.succeed("test /run/netns/maxops -ef /run/netns/" + first)
    machine.fail(execute(first, "test -S /run/max-ops-tailscale/tailscaled.sock"))
    host_id = machine.succeed("tailscale status --json | jq -r .Self.ID").strip()
    ops_cli = "tailscale --socket=/run/max-ops-tailscale/tailscaled.sock "
    ops_id = machine.succeed(ops_cli + "status --json | jq -r .Self.ID").strip()
    assert host_id != ops_id
    machine.succeed(cli + f"remove {second}")
    machine.succeed(execute(first, "ssh fleet 'sudo -n true'"))
    machine.succeed("systemctl restart max.service")
    machine.succeed(execute(first, "cat /work/keep | grep durable"))
    fleet_ip = control.succeed("tailscale ip -4").strip()
    machine.succeed("systemctl stop max-ops-tailscaled", timeout=90)
    machine.fail(execute(first, f"ssh -o ConnectTimeout=3 {fleet_ip} true"))
    machine.succeed("systemctl start max-ops-tailscaled", timeout=90)
    machine.wait_until_succeeds(execute(first, "ssh fleet true"), timeout=90)
    assert machine.succeed(ops_cli + "status --json | jq -r .Self.ID").strip() == ops_id
    machine.succeed("/run/current-system/specialisation/revoked/bin/switch-to-configuration test", timeout=180)
    machine.fail(execute(first, "ssh fleet true"))
    assert machine.succeed(cli + "network 123").strip() == "max-sandbox"
    create(first, "max-sandbox")
    machine.succeed(execute(first, "cat /work/keep | grep durable"))
    assert machine.succeed(cli + f"policy {first}").strip() == "7 max-sandbox 1"
    machine.succeed("systemctl stop max-stack.target", timeout=120)
    machine.wait_until_succeeds("test ! -e /run/netns/maxops", timeout=60)
    machine.succeed("systemctl is-active tailscaled")
    machine.succeed("test -s /var/lib/max/tailscale/tailscaled.state")
    machine.succeed("systemctl start max-stack.target", timeout=120)
    machine.wait_for_unit("max-ops-tailscaled.service")
    assert machine.succeed(ops_cli + "status --json | jq -r .Self.ID").strip() == ops_id
    assert machine.succeed("systemctl show max-ops-tailscaled -p Slice --value").strip() == "max.slice"
  '';
}
