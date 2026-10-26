{ pkgs }:
let
  inherit (pkgs) lib;
  # Reuse the community project's QQ/NapCat integration, pinned as one input.
  source = builtins.fetchTarball {
    url = "https://codeload.github.com/initialencounter/napcat.nix/tar.gz/a157f1524a594d7d78409f81d448145fe12218e7";
    sha256 = "sha256-ac5ntKexwDJ50QvDXx0Q1HzlRv1SeS20/hJ32uXfhr0=";
  };
  upstream = pkgs.callPackage "${source}/src/napcat.nix" { };
  # QQ is pinned here rather than taken from the host's nixpkgs, whose stable
  # release lags months behind; NapCat 4.18.41 lists 3.2.34-53644 as
  # supported. Hashes match nixpkgs' sources.nix for the same release.
  qqVersion = "3.2.34-2026-09-24";
  qqRelease =
    {
      x86_64-linux = {
        url = "https://qqdl.gtimg.cn/qqfile/QQNTV2/9.9.36/release/9ee04bef/QQ_3.2.34_260924_amd64_01.deb";
        hash = "sha256-Q2xl4d0oQi4SiiHL3bX+Ti5sB51/J/7CVB4BTTjMM24=";
      };
      aarch64-linux = {
        url = "https://qqdl.gtimg.cn/qqfile/QQNTV2/9.9.36/release/9ee04bef/QQ_3.2.34_260924_arm64_01.deb";
        hash = "sha256-GBuJXLVzVI45blS7BUjMqS/9wbGksBj6RVG7BiOF/co=";
      };
    }
    .${pkgs.stdenv.hostPlatform.system};
  # Tencent's download host answers 403 to an unsigned URL; its public signing
  # endpoint returns a short-lived one, as nixpkgs' own fetcher does.
  qqSource =
    pkgs.runCommandLocal (baseNameOf qqRelease.url)
      {
        outputHash = qqRelease.hash;
        outputHashMode = "flat";
        nativeBuildInputs = [
          pkgs.curl
          pkgs.jq
          pkgs.cacert
        ];
      }
      ''
        signedUrl=$(
          curl -fsS --retry 3 -X POST "https://im.qq.com/http2rpc/gotrpc/noauth/trpc.qqntv2.urlsign.UrlSign/GetSign" \
            -H "Content-Type: application/json" \
            -H 'x-oidb: {"uint32_command":"0x9b8e","uint32_service_type":1}' \
            -d '{"url":"${qqRelease.url}"}' | jq -er '.data.url'
        )
        curl -fL --retry 3 -o "$out" "$signedUrl"
      '';
  napcat = upstream.patched.overrideAttrs {
    src = qqSource;
    version = "${qqVersion}-napcat-4.18.41";
    meta = pkgs.qq.meta // {
      mainProgram = "qq";
    };
  };
  fonts = pkgs.makeFontsConf { fontDirectories = [ pkgs.source-han-sans ]; };
  inner = pkgs.writeShellScript "max-napcat-inner" ''
    set -eu
    export HOME=/root
    export XDG_DATA_HOME=/root/.local/share
    export XDG_CONFIG_HOME=/root/.config
    export FONTCONFIG_FILE=${fonts}
    export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
    export PATH=${
      lib.makeBinPath [
        pkgs.coreutils
        pkgs.bash
        pkgs.xorg-server
        pkgs.procps
      ]
    }
    mkdir -p /usr/bin /bin /root/.local/share
    ln -s ${pkgs.coreutils}/bin/env /usr/bin/env
    ln -s ${pkgs.bash}/bin/sh /bin/sh
    # Preserve persisted configuration when copying upstream's runtime files.
    cp -r --update=none ${napcat}/napcat/. /root/napcat/
    Xvfb -displayfd 3 -nolisten tcp 3>/tmp/xvfb-display >/dev/null 2>&1 &
    display_pid=$!
    trap 'kill "$display_pid" 2>/dev/null || true' EXIT
    for _ in $(seq 1 100); do
      test -s /tmp/xvfb-display && break
      kill -0 "$display_pid"
      sleep 0.1
    done
    test -s /tmp/xvfb-display
    export DISPLAY=":$(cat /tmp/xvfb-display)"
    ${napcat}/bin/qq --no-sandbox "$@"
  '';
in
pkgs.writeShellApplication {
  name = "max-napcat";
  runtimeInputs = [ pkgs.bubblewrap ];
  text = ''
    : "''${MAX_NAPCAT_QQ_DIR:?}" "''${MAX_NAPCAT_CONFIG_DIR:?}" "''${MAX_NAPCAT_OUTBOX_DIR:?}"
    exec bwrap --unshare-all --share-net --as-pid-1 --uid 0 --gid 0 --clearenv \
      --ro-bind /nix/store /nix/store \
      --ro-bind /etc/resolv.conf /etc/resolv.conf \
      --ro-bind ${pkgs.tzdata}/share/zoneinfo/Asia/Shanghai /etc/localtime \
      --bind "$MAX_NAPCAT_CONFIG_DIR" /root/napcat/config \
      --bind "$MAX_NAPCAT_QQ_DIR" /root/.config/QQ \
      --ro-bind "$MAX_NAPCAT_OUTBOX_DIR" /data/outbox \
      --proc /proc --dev /dev --tmpfs /tmp \
      ${inner} "$@"
  '';
  derivationArgs.passthru = { inherit napcat source; };
}
