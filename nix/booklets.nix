# The Typst booklets under booklets/, each built to a PDF offline: Typst's
# packages and the fonts come from nixpkgs.
{ pkgs }:
let
  typst = pkgs.typst.withPackages (typstPackages: [
    typstPackages.cetz_0_4_2
    typstPackages.fletcher_0_5_8
    typstPackages.droplet_0_3_1
  ]);
  fontPaths = pkgs.lib.concatMapStringsSep ":" toString [
    pkgs.eb-garamond
    pkgs.ibm-plex
    pkgs.dejavu_fonts
  ];
  # Every directory except the shared theme is one booklet.
  names = builtins.attrNames (
    pkgs.lib.filterAttrs (name: kind: kind == "directory" && name != "shared") (
      builtins.readDir ../booklets
    )
  );
in
{
  # booklets/<name>/ becomes <name>.pdf.
  package = pkgs.stdenvNoCC.mkDerivation {
    name = "oversight-booklets";
    src = ../booklets;
    nativeBuildInputs = [ typst ];
    env.TYPST_FONT_PATHS = fontPaths;
    dontConfigure = true;
    dontInstall = true;
    buildPhase = ''
      for name in ${pkgs.lib.escapeShellArgs names}; do
        bash build.sh "$name" "$out"
      done
    '';
  };

  # `nix develop .#booklets`: Typst and the fonts, for writing a booklet
  # with `typst watch`.
  shell = pkgs.mkShell {
    packages = [ typst ];
    TYPST_FONT_PATHS = fontPaths;
  };
}
