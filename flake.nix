{
  description = "fallout1-mcp - Fallout Community Edition, driven over MCP";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            # On Linux CMake links the system SDL2; on macOS it builds its own
            # copy via FetchContent, as do fpattern and adecode everywhere, so
            # the first configure needs network and git.
            packages = [
              pkgs.cmake
              pkgs.SDL2
              pkgs.git
              # The MCP bridge (bridge/) runs on bun.
              pkgs.bun
            ];

            # The engine passes non-literal format strings, which nixpkgs'
            # -Werror=format-security rejects. nixpkgs' fallout-ce does the same.
            hardeningDisable = [ "format" ];
          };
        });
    };
}
