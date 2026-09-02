{
  description = "Development environment for Lean Scout";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      mkFhsShell =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        pkgs.buildFHSEnv {
          name = "lean-scout-dev";
          targetPkgs = fhsPkgs: with fhsPkgs; [
            elan
            gh
            git
            python313
            uv
          ];
          profile = ''
            export UV_PYTHON=${pkgs.python313}/bin/python3.13
            export UV_PYTHON_DOWNLOADS=never
          '';
          runScript = "bash";
        };
    in
    {
      devShells = forAllSystems (system: {
        # uv's locked environment contains upstream manylinux wheels. The FHS
        # shell provides their standard Linux interpreter and libraries.
        default = (mkFhsShell system).env;
      });

      apps = forAllSystems (
        system:
        let
          fhsShell = mkFhsShell system;
        in
        {
          dev-shell = {
            type = "app";
            program = "${fhsShell}/bin/lean-scout-dev";
            meta.description = "Run the Lean Scout FHS development shell";
          };
        }
      );
    };
}
