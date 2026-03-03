# anvil.nix - Anvil Docker image package definitions
#
# Builds the hopr-anvil Docker image: a local Ethereum node pre-loaded with
# HOPR contracts compiled at image build time via fakeRootCommands.
# Also provides an upload script for pushing the image to a registry.

{
  pkgs,
  lib,
  foundryBin,
  solcDefault,
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
      (root + "/scripts/run-local-anvil.sh")
      (root + "/scripts/utils.sh")
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
    contents = with pkgs; [
      anvilSrc
      coreutils
      curl
      findutils
      foundryBin
      gnumake
      jq
      lsof
      runtimeShellPackage
      solcDefault
      time
      tini
      which
    ];
    enableFakechroot = true;
    fakeRootCommands = ''
      #!${pkgs.runtimeShell}

      # must generate the foundry.toml here
      if ! grep -q "solc = \"${solcDefault}/bin/solc\"" /ethereum/contracts/foundry.toml; then
        echo "solc = \"${solcDefault}/bin/solc\""
        echo "Generating foundry.toml file!"
        sed "s|# solc = .*|solc = \"${solcDefault}/bin/solc\"|g" \
          /ethereum/contracts/foundry.in.toml >| \
          /ethereum/contracts/foundry.toml
      else
        echo "foundry.toml file already exists!"
      fi

      # rewrite remappings to use absolute paths to fix solc checks
      sed -i \
        's|../../vendor/|/vendor/|g' \
        /ethereum/contracts/remappings.txt

      # unlink all linked files/directories, because forge does
      # not work well with those
      cp -R -L /ethereum/contracts /ethereum/contracts-unlinked
      rm -rf /ethereum/contracts
      mv /ethereum/contracts-unlinked /ethereum/contracts

      # need to point to the contracts directory for forge to work
      ${foundryBin}/bin/forge build --root /ethereum/contracts
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
    OCI_ARCHIVE="$(nix build --no-link --print-out-paths ${anvil-docker})"
    ${pkgs.skopeo}/bin/skopeo copy --insecure-policy \
      --dest-registry-token="$GOOGLE_ACCESS_TOKEN" \
      "docker-archive:$OCI_ARCHIVE" "docker://$IMAGE_TARGET"
    echo "Uploaded image to $IMAGE_TARGET"
  '';
in
{
  inherit anvil-docker anvil-docker-upload;
}
