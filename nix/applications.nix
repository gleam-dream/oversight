{ pkgs, gleam }:
let
  inherit (pkgs) lib;
  gitHashes = import ./git-sources.nix;
  names = [
    "checkout"
    "email_portal"
    "extractor"
    "financial_recovery"
    "research_agent"
    "secure_mcp"
    "session_replay"
    "sso_portal"
    "support_desk"
    "tool_hub"
    "webhooks"
  ];
  importApplication =
    name:
    let
      src = ../apps + "/${name}";
      locked = gleam.readManifest (src + "/manifest.toml");
      gitPackages = builtins.filter (package: package.source == "git") locked.packages;
      rebarPackages = builtins.filter (
        package: !(builtins.elem "gleam" package.build_tools) && builtins.elem "rebar3" package.build_tools
      ) locked.packages;
      project = gleam.importProject {
        inherit src;
        sourceOverrides = lib.listToAttrs (
          map (package: {
            name = package.name;
            value =
              let
                source = pkgs.fetchFromGitHub {
                  owner = "gleam-dream";
                  repo = lib.removeSuffix ".git" (baseNameOf package.repo);
                  rev = package.commit;
                  hash =
                    gitHashes.${package.repo}.${package.commit}
                      or (throw "Register the locked Git source hash for ${package.name} in nix/git-sources.nix.");
                };
              in
              "${source}/${package.path or "."}";
          }) gitPackages
        );
        packageOverrides =
          final: _prev:
          lib.listToAttrs (
            map (package: {
              name = package.name;
              value = gleam.fromBeamPackage {
                pname = package.name;
                inherit (package) version;
                otpAppName = package.otp_app or package.name;
                package =
                  (gleam.beamPackages.buildRebar3 {
                    name = package.otp_app or package.name;
                    inherit (package) version;
                    src = project.sources.${package.name};
                    beamDeps = map (dependency: final.${dependency}) package.requirements;
                  }).overrideAttrs
                    (previous: {
                      postInstall = (previous.postInstall or "") + ''
                        # Some Erlang consumers include headers retained in src/.
                        appSource="$out"/${lib.escapeShellArg "lib/erlang/lib/${package.otp_app or package.name}-${package.version}/src"}
                        if [ -d "$out/src/src" ] && [ ! -e "$appSource" ]; then
                          ln -s "$out/src/src" "$appSource"
                        fi
                      '';
                    });
              };
            }) rebarPackages
          );
      };
    in
    project;
in
lib.genAttrs names importApplication
