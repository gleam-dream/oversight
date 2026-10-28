{
  description = "Development environment for oversight";

  inputs = {
    design-layer.url = "github:lostbean/design-layer/main";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    gleam-nix = {
      url = "github:gleam-dream/gleam-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      design-layer,
      nixpkgs,
      gleam-nix,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        gleamBuild = (gleam-nix.lib.mkLib pkgs).overrideScope (
          _: _: {
            beamPackages = pkgs.beam29Packages;
          }
        );
        applications = import ./nix/applications.nix {
          inherit pkgs;
          gleam = gleamBuild;
        };

        # One derivation shared by the devShell and the mix-format formatter,
        # so `nix fmt` never formats with a different Elixir/OTP than the
        # shell actually runs prototypes on.
        elixirPackage = pkgs.beam29Packages.elixir_1_20;

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
          ];
          programs.gleam.enable = true;
          programs.mix-format = {
            enable = true;
            package = elixirPackage;
          };
          programs.shfmt.enable = true;
          settings.formatter.shfmt.includes = pkgs.lib.mkForce [ "scripts/test-*.sh" ];
          settings.formatter.shfmt.options = [
            "-i"
            "2"
          ];
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
        };
      in
      {
        # Realized only when the schema comparison invokes this app.
        apps.oracle-mcp-schema = {
          type = "app";
          program = "${pkgs.writeShellScript "oracle-mcp-schema" ''
            printf '%s\n' ${
              pkgs.fetchurl {
                name = "mcp-2026-07-28-schema.json";
                url = "https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/5f5440bb26a62e2cf3440b92da5a667efa03b267/schema/2026-07-28/schema.json";
                sha256 = "ef70b61f99b6d2e5e3b46863822eab08dff6a45bedc7a08914e0e5b133f40203";
              }
            }
          ''}";
        };
        apps.snips = design-layer.apps.${system}.snips;
        apps.design-gate-check = design-layer.apps.${system}.check;
        apps.design-gate-render = design-layer.apps.${system}.render;
        apps.design-gate-context = design-layer.apps.${system}.context;

        devShells.default = pkgs.mkShell {
          # Prototyping/eval/test toolchain for the ported designs: Gleam
          # against its own target runtime (Erlang/OTP + rebar3), plus
          # Elixir to run the upstream libraries (Oban, Reactor, oidcc, ...)
          # side by side for direct behavioral comparison.
          packages = with pkgs; [
            git
            lefthook
            gleam
            beam29Packages.erlang
            beam29Packages.rebar3
            elixirPackage
            # Disposable clusters for the composition apps (Grind, Fabric, Saga storage).
            postgresql_16
            (python3.withPackages (pythonPackages: [ pythonPackages.jsonschema ]))
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        packages = pkgs.lib.mapAttrs (_: project: project.package) applications;

        checks = {
          formatting = treefmtEval.config.build.check ./.;
          shared-dependencies =
            assert
              builtins.length (
                pkgs.lib.unique (
                  map (project: project.packages.gleam_stdlib.drvPath) (builtins.attrValues applications)
                )
              ) == 1;
            assert
              applications.checkout.packages.saga_postgres.drvPath
              == applications.financial_recovery.packages.saga_postgres.drvPath;
            pkgs.runCommand "oversight-shared-dependencies" { } "touch $out";
        }
        // pkgs.lib.mapAttrs' (
          name: project:
          pkgs.lib.nameValuePair "${name}-loads" (
            pkgs.runCommand "oversight-${name}-loads"
              {
                nativeBuildInputs = [ gleamBuild.erlang ];
                buildInputs = [ project.package ];
              }
              ''
                erl -noshell -eval '
                  {ok, _} = application:ensure_all_started(${name}),
                  halt(0).'
                touch "$out"
              ''
          )
        ) applications;
      }
    );
}
