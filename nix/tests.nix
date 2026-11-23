# One test check per application, run in the Nix sandbox. Applications whose
# tests need PostgreSQL get a fresh cluster per check, laid out as
# apps/scripts/with-postgres.sh lays it out for `gleam test`.
{
  pkgs,
  gleam,
  projects,
}:
let
  inherit (pkgs) lib;
  database = gleam.testServices.postgresql {
    package = pkgs.postgresql_16;
    init = "create role app login superuser; create database app owner app;";
    env = {
      PGHOST = "127.0.0.1";
      PGPORT = "$SERVICE_PORT";
      PGUSER = "app";
      PGDATABASE = "app";
    };
    aliases.DATABASE_URL = "postgres://app@127.0.0.1:$SERVICE_PORT/app";
  };
  withoutDatabase = [
    "email_portal"
    "moderation_desk"
    "session_replay"
    "support_desk"
    "tool_hub"
  ];
in
lib.mapAttrs (
  name: project:
  gleam.mkTestCheck {
    inherit project;
    services = lib.optional (!(builtins.elem name withoutDatabase)) database;
  }
) projects
