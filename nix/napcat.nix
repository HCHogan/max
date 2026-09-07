{ pkgs }:
let
  inherit (pkgs) lib;
  # Reuse the community project's QQ/NapCat integration, pinned as one input.
  source = builtins.fetchTarball {
    url = "https://codeload.github.com/initialencounter/napcat.nix/tar.gz/cefa2c2832ad1a38cfcc3c3994c7101d7ec80ad3";
    sha256 = "sha256-iHBAT/lr1vLoz2KqEs0Q886K5AC3x5gWWW91lVpT/Z4=";
  };
  upstream = pkgs.callPackage "${source}/src/napcat.nix" { };
  # Tencent removes old release URLs. This mirror has the identical bytes:
  # keep nixpkgs' independently pinned hash, including on the fallback URL.
  qqSource = pkgs.qq.src.overrideAttrs (old: {
    urls =
      old.urls
      ++
        lib.optional (pkgs.qq.version == "3.2.29-2026-05-28")
          "https://github.com/Rodert/qq-versions/releases/download/qq-packages-20260528-3e8913a2/QQ_3.2.29_260528_${
            if pkgs.stdenv.hostPlatform.isx86_64 then "amd64" else "arm64"
          }_01.deb";
  });
  napcat = upstream.patched.overrideAttrs {
    # Keep the fleet's pinned QQ release; upstream otherwise downgrades QQ.
    src = qqSource;
    version = "${pkgs.qq.version}-napcat-4.18.19";
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
