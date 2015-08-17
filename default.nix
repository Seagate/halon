let
  pkgs        = import <nixpkgs> {};
  stdenv      = pkgs.stdenv;
  hpkgs       = pkgs.haskellPackages_ghc783;
  cep         = import ./cep hpkgs;
  gloss       = hpkgs.gloss.override { bmp = hpkgs.bmp.override { binary = hpkgs.binary; }; };
in
  stdenv.mkDerivation {
    name        = "tweag-cep";
    src         = ./.;
    version     = "0.1.0.0";
    buildInputs = [
      cep

      hpkgs.networkTransportTcp hpkgs.random hpkgs.stm hpkgs.multimap hpkgs.lens hpkgs.distributedProcess gloss
      
      hpkgs.ghc hpkgs.cabalInstall pkgs.git pkgs.less pkgs.openssh pkgs.gv pkgs.glibc
    ];
    buildCommand = "true";
  }
