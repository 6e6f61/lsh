{
  inputs.nixpkgs.url = "nixpkgs/nixos-unstable";
  inputs.zig.url = "github:mitchellh/zig-overlay";

  outputs = { nixpkgs, zig, ... }:
  let pkgs = nixpkgs.legacyPackages.x86_64-linux;
      zig' = zig.packages.x86_64-linux.master;
  in
  {
    devShells.x86_64-linux.default = pkgs.mkShell
      { buildInputs = with pkgs; [ zig' ]; };
  };
}