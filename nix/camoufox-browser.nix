{ pkgs }:
let
  version = "152.0.4";
  release = "beta.28";
  ublockOriginVersion = "1.72.2";
  geoLiteVersion = "2026.08.01";
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
  browserArchive = pkgs.fetchurl {
    url = "https://github.com/daijro/camoufox/releases/download/v${version}-${release}/camoufox-${version}-${release}-lin.${asset.archiveArch}.zip";
    inherit (asset) hash;
  };
  ublockOrigin = pkgs.fetchurl {
    url = "https://addons.mozilla.org/firefox/downloads/file/4888680/ublock_origin-${ublockOriginVersion}.xpi";
    hash = "sha256-QMMVsNp4cYaBVez656UKWN+gkgrr2GXgCCFJhvG3xXg=";
  };
  geoLiteCity = pkgs.fetchurl {
    url = "https://github.com/P3TERX/GeoLite.mmdb/releases/download/${geoLiteVersion}/GeoLite2-City.mmdb";
    hash = "sha256-bmaEyrBOu6EMHqn0pEMXXKD/CA4lXoT57wNQUXWCZX4=";
  };
in
{
  inherit
    version
    release
    ublockOriginVersion
    geoLiteVersion
    ublockOrigin
    geoLiteCity
    ;
  archive = browserArchive;
  bundle = pkgs.linkFarm "camoufox-runtime-assets" [
    {
      name = "camoufox-browser.zip";
      path = browserArchive;
    }
    {
      name = "ublock-origin.xpi";
      path = ublockOrigin;
    }
    {
      name = "GeoLite2-City.mmdb";
      path = geoLiteCity;
    }
  ];
}
