{ pkgs }:
let
  version = "152.0.4";
  release = "beta.28";
  ublockOriginVersion = "1.72.2";
  geoLiteVersion = "1.0.96";
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
  # Use a versioned npm archive: the previous daily GitHub release was deleted
  # upstream. Extract only the database; execute no package lifecycle scripts.
  geoLiteArchive = pkgs.fetchurl {
    url = "https://registry.npmjs.org/geolite2-city/-/geolite2-city-${geoLiteVersion}.tgz";
    hash = "sha512-33sKqF3F6VldBI4vpY8+wKR4PnS7x15RHXz3jdoo63pYQB4dqB6znHNs5NqYAgMKqRvFpqzZ//py+xXgIJGQyg==";
  };
  geoLiteCity = pkgs.runCommand "GeoLite2-City.mmdb" { } ''
    tar -xzOf ${geoLiteArchive} package/GeoLite2-City.mmdb.gz | gzip -d > "$out"
  '';
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
