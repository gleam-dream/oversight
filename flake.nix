{
  description = "Development environment for oversight";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        # One derivation shared by the devShell and the mix-format formatter,
        # so `nix fmt` never formats with a different Elixir/OTP than the
        # shell actually runs prototypes on.
        elixirPackage = pkgs.beam28Packages.elixir;

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
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          # Prototyping/eval/test toolchain for the ported designs: Gleam
          # against its own target runtime (Erlang/OTP + rebar3), plus
          # Elixir to run the upstream libraries (Oban, Reactor, oidcc, ...)
          # side by side for direct behavioral comparison.
          packages = with pkgs; [
            lefthook
            gleam
            beam28Packages.erlang
            rebar3
            elixirPackage
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
