{ pkgs }:
let
  version = "152.0.4";
  release = "beta.28";
  assets = {
    x86_64-linux = {
      archiveArch = "x86_64";
      hash = "sha256-kk8xCczW1HzWoDhNZ6NF+t+XXUi2MZ+Nu9WVTFiJgr0=";
    };
    aarch64-linux = {
      archiveArch = "arm64";
      hash = "sha256-OhBaL8kp6Ap5tLf84sk+1ixPssh388HtKl1mocT+lo8=";
    };
  };
  asset =
    assets.${pkgs.stdenv.hostPlatform.system}
      or (throw "max camoufox browser: unsupported system ${pkgs.stdenv.hostPlatform.system}");
in
{
  inherit version release;
  archive = pkgs.fetchurl {
    url = "https://github.com/daijro/camoufox/releases/download/v${version}-${release}/camoufox-${version}-${release}-lin.${asset.archiveArch}.zip";
    inherit (asset) hash;
  };
}
