# This file was auto-generated by cabal2nix. Please do NOT edit manually!

{ cabal, binary, distributedProcess, lens, mtl, networkTransport,
  networkTransportTcp, multimap, ... }:

cabal.mkDerivation (self: {
  pname = "cep";
  version = "0.1.0.0";
  src = ./.;
  sha256 = "TODO";
  buildDepends = [
    binary distributedProcess lens mtl networkTransport networkTransportTcp
    multimap
  ];
  extraConfigureFlags = [ "--enable-library-profiling" ];
  meta = {
    description = "A Complex Event Processing framework";
    license = self.stdenv.lib.licenses.unfree;
    platforms = self.ghc.meta.platforms;
  };
})
