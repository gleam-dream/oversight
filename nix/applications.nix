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
    in
    gleam.importProject {
      inherit src includeDev;
      sourceOverrides = gleam.gitSources { inherit manifest registry; };
      # Rebar3 dependencies build with Nixpkgs' builder on the scope's OTP.
      buildForeign = true;
    };
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
