# opencli: commands for common sites (bilibili, Zhihu, Xiaohongshu,
# Reddit and a hundred more) that know each site's own API, run in the
# group's browser with its logins. The command on the guest's PATH is
# opencli.js, which gives each command a tab of its own. See "opencli"
# under 浏览器 in docs/rust-rewrite.md.
#
# The package is npm's, pinned. The lock is ours: npm's package has none,
# so opencli-lock.json was made (npm install --package-lock-only) from its
# package.json without the dev dependencies and scripts, which the build
# drops too, as npm ci wants the two to agree.
{ pkgs }:
let
  opencli = pkgs.buildNpmPackage {
    pname = "opencli";
    version = "2.0.2";
    src = pkgs.fetchurl {
      url = "https://registry.npmjs.org/@jackwener/opencli/-/opencli-2.0.2.tgz";
      hash = "sha512-+O+S+FQikiVunP/alMG//ww9D1lpgA24+C6ifyyzI4rZVT6GEJVqaiGZWbyI2i/Hcocs4l1K6gnNt+3Yaf2wtw==";
    };
    postPatch = ''
      ${pkgs.jq}/bin/jq 'del(.devDependencies, .scripts)' package.json > package.json.new
      mv package.json.new package.json
      cp ${./opencli-lock.json} package-lock.json
    '';
    npmDepsHash = "sha256-euHcZiz76lnFzzZ3/wzrnkB0BCpcMNF+E9RS/KcjsTs=";
    dontNpmBuild = true;
  };
in
pkgs.writeShellScriptBin "opencli" ''
  exec ${pkgs.nodejs}/bin/node ${./opencli.js} ${opencli}/bin/opencli "$@"
''
