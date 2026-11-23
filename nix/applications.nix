{ pkgs, gleam }:
let
  inherit (pkgs) lib;
  registry = import ./git-sources.nix;
  names = [
    "checkout"
    "clinic_registration"
    "email_portal"
    "extractor"
    "financial_recovery"
    "moderation_desk"
    "payout_desk"
    "research_agent"
    "secure_mcp"
    "session_replay"
    "sso_portal"
    "support_desk"
    "tool_hub"
    "webhooks"
  ];
  importApplication =
    { includeDev }:
    name:
    let
      src = ../apps + "/${name}";
      manifest = src + "/manifest.toml";
      locked = gleam.readManifest manifest;
      rebarPackages = builtins.filter (
        package: !(builtins.elem "gleam" package.build_tools) && builtins.elem "rebar3" package.build_tools
      ) locked.packages;
      project = gleam.importProject {
        inherit src includeDev;
        sourceOverrides = gleam.gitSources { inherit manifest registry; };
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
{
  # The release build of each application.
  projects = lib.genAttrs names (importApplication {
    includeDev = false;
  });
  # The same applications with their test code and development dependencies.
  tested = lib.genAttrs names (importApplication {
    includeDev = true;
  });
}
