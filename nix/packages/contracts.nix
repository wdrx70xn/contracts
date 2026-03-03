# contracts.nix - HOPR contracts Rust package definitions
#
# Builds the hopr-bindings library for multiple platforms using nix-lib builders.
# Source filtering, rev, and build arguments are all defined here.
# The contracts-specific preConfigure generates foundry.toml from foundry.in.toml
# (only for the main build; the deps-only build does not need it).

{
  builders,
  nixLib,
  self,
  lib,
  foundryBin,
  solcDefault,
}:
let
  fs = lib.fileset;
  root = ./../..;

  rev = toString (self.shortRev or self.dirtyShortRev);

  depsSrc = nixLib.mkDepsSrc {
    inherit root fs;
  };

  src = nixLib.mkSrc {
    inherit root fs;
    # Extra files not covered by the default .rs/.toml extensions
    extraFiles = [
      (root + "/ethereum/bindings/contracts-addresses.json")
      (root + "/ethereum/contracts/remappings.txt")
      (fs.fileFilter (file: file.hasExt "sol") (root + "/vendor/solidity"))
      (fs.fileFilter (file: file.hasExt "sol") (root + "/ethereum/contracts/src"))
    ];
  };

  cargoToml = ./../../ethereum/bindings/Cargo.toml;

  buildArgs = {
    inherit src depsSrc rev cargoToml;
    # foundryBin and solcDefault are required as native build tools
    extraNativeBuildInputs = [
      foundryBin
      solcDefault
    ];
  };

  # Extend a package's preConfigure to generate foundry.toml from foundry.in.toml.
  # This is only added to the main package derivation, not to the cargoArtifacts
  # (deps-only build), since depsSrc does not include foundry.in.toml.
  withFoundryPreConfigure =
    pkg:
    pkg.overrideAttrs (old: {
      preConfigure =
        (old.preConfigure or "")
        + ''
          sed "s|# solc = .*|solc = \"${solcDefault}/bin/solc\"|g" \
            ethereum/contracts/foundry.in.toml > \
            ethereum/contracts/foundry.toml
        '';
    });

  build =
    builder: args:
    withFoundryPreConfigure (builder.callPackage nixLib.mkRustPackage (buildArgs // args));
in
{
  build-dev = build builders.local {
    CARGO_PROFILE = "dev";
    cargoExtraArgs = "-F capture";
  };

  clippy = build builders.local { runClippy = true; };

  test = build builders.local { runTests = true; };

  test-nightly = build builders.localNightly {
    runTests = true;
    cargoExtraArgs = "-Z panic-abort-tests";
  };

  docs = build builders.localNightly { buildDocs = true; };

  # Cross-compiled library packages
  lib-contracts-x86_64-linux = build builders."x86_64-linux" { };
  lib-contracts-x86_64-darwin = build builders."x86_64-darwin" { };
  lib-contracts-aarch64-darwin = build builders."aarch64-darwin" { };
  lib-contracts = build builders.local { };
}
