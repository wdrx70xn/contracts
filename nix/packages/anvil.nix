# anvil.nix - Anvil Docker image package definitions
#
# Builds the hopr-anvil Docker image: a local Ethereum node pre-loaded with
# HOPR contracts compiled at image build time via fakeRootCommands.
# Also provides an upload script for pushing the image to a registry.

{
  pkgs, # native build-system pkgs (dockerTools + fakeRootCommands tools)
  pkgsLinux, # x86_64-linux pkgs (container runtime contents)
  lib,
  foundryBin, # x86_64-linux foundry (container runtime)
  solcDefault, # native solc (build-time forge compilation in fakeRootCommands)
  linuxSolcDefault, # x86_64-linux solc (container runtime, embedded in foundry.toml)
}:
let
  fs = lib.fileset;
  root = ./../..;

  anvilSrc = fs.toSource {
    inherit root;
    fileset = fs.unions [
      (root + "/ethereum/bindings/contracts-addresses.json")
      (root + "/ethereum/contracts/foundry.in.toml")
      (root + "/ethereum/contracts/remappings.txt")
      (root + "/ethereum/contracts/Makefile")
      (root + "/Makefile")
      (fs.fileFilter (file: file.hasExt "sol") (root + "/vendor/solidity"))
      (fs.fileFilter (file: file.hasExt "sol") (root + "/ethereum/contracts/src"))
      (fs.fileFilter (file: file.hasExt "sol") (root + "/ethereum/contracts/script"))
      (fs.fileFilter (file: file.hasExt "sol") (root + "/ethereum/contracts/test"))
    ];
  };

  anvil-docker = pkgs.dockerTools.buildLayeredImage {
    name = "hopr-anvil";
    tag = "latest";
    # breaks binary reproducibility, but makes usage easier
    created = "now";
    # Use Linux packages for the container contents so the image can be built
    # on Darwin as well as Linux.
    contents =
      [ anvilSrc ]
      ++ (with pkgsLinux; [
        coreutils
        curl
        findutils
        foundryBin
        gnumake
        jq
        lsof
        runtimeShellPackage
        linuxSolcDefault
        time
        tini
        which
      ]);
    fakeRootCommands = ''
      #!${pkgs.runtimeShell}
      set -euo pipefail

      # Copy contract sources from the Nix store via their store path.
      # Store paths are accessible without fakechroot; -L dereferences all
      # symlinks so forge does not trip over them.
      mkdir -p ethereum/contracts
      cp -rL ${anvilSrc}/ethereum/contracts/. ethereum/contracts/
      chmod -R u+w ethereum/contracts

      # Generate foundry.toml using the NATIVE solc so that forge can run
      # the compilation on the build host (Solidity → EVM bytecode is
      # platform-agnostic, so a Darwin forge produces identical artifacts).
      ${pkgs.gnused}/bin/sed \
        "s|# solc = .*|solc = \"${solcDefault}/bin/solc\"|g" \
        ethereum/contracts/foundry.in.toml >| \
        ethereum/contracts/foundry.toml

      # Rewrite the relative vendor paths (../../vendor/) in both foundry.toml
      # (allow_paths) and remappings.txt to the absolute Nix store path so
      # solc can resolve imports without a /vendor symlink in the image.
      ${pkgs.gnused}/bin/sed -i \
        "s|../../vendor/|${anvilSrc}/vendor/|g" \
        ethereum/contracts/foundry.toml \
        ethereum/contracts/remappings.txt

      # Pre-compile contracts using native forge + native solc.
      HOME=$(${pkgs.coreutils}/bin/mktemp -d) \
        ${pkgs.foundry-bin}/bin/forge build --root ethereum/contracts

      # Replace the native solc path with the Linux one so that the container
      # (always x86_64-linux) can invoke solc at runtime if needed.
      ${pkgs.gnused}/bin/sed -i \
        "s|${solcDefault}/bin/solc|${linuxSolcDefault}/bin/solc|" \
        ethereum/contracts/foundry.toml
    '';
    config = {
      Cmd = [
        "/bin/tini"
        "--"
        "bash"
        "/scripts/run-local-anvil.sh"
      ];
      ExposedPorts = {
        "8545/tcp" = { };
      };
    };
  };

  anvil-docker-upload = pkgs.writeShellScriptBin "docker-image-upload" ''
    set -eu
    OCI_ARCHIVE="${anvil-docker}"
    ${pkgs.skopeo}/bin/skopeo copy --insecure-policy \
      --dest-registry-token="$GOOGLE_ACCESS_TOKEN" \
      "docker-archive:$OCI_ARCHIVE" "docker://$IMAGE_TARGET"
    echo "Uploaded image to $IMAGE_TARGET"
  '';
in
{
  inherit anvil-docker anvil-docker-upload;
}
