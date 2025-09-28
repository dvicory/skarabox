{
  config,
  lib,
  inputs,
  ...
}:
let
  topLevelConfig = config;
  cfg = config.skarabox;

  inherit (lib) concatMapAttrs mapAttrs;
in
{
  config = {
    perSystem = { inputs', ... }: {
      apps = {
        inherit (inputs'.colmena.apps) colmena;
      };
    };

    flake = flakeInputs: let
      mkFlake = name: cfg': {
        colmenaHive = inputs.colmena.lib.makeHive ({
          meta.nixpkgs = import inputs.nixpkgs { system = "x86_64-linux"; };
          meta.nodeNixpkgs = mapAttrs (_: cfg': import cfg'.nixpkgs { inherit (cfg') system; }) cfg.hosts;
        } // (let
          mkNode = name: cfg': let
            hostCfg = topLevelConfig.flake.nixosConfigurations.${name}.config;
            runtimeKeyPath = "${name}/runtime_host_key";
            runtimeKeyPubPath = "${name}/runtime_host_key.pub";
          in
            {
              deployment = {
                targetHost = cfg'.ip;
                targetPort = hostCfg.skarabox.sshPort;
                targetUser = topLevelConfig.flake.nixosConfigurations.${name}.config.skarabox.username;
                sshOptions = [
                  "-o" "IdentitiesOnly=yes"
                  "-o" "UserKnownHostsFile=${cfg'.knownHosts}"
                  "-o" "ConnectTimeout=10"
                ] ++ lib.optionals (cfg'.sshPrivateKeyPath != null) [ "-i" cfg'.sshPrivateKeyPath ];

                # Deploy runtime SSH keys for dual SSH key migration
                keys = lib.optionalAttrs (cfg'.runtimeHostKeyPub != null) {
                  "runtime_host_key" = {
                    keyCommand = ["cat" runtimeKeyPath];
                    destDir = "/tmp";
                    user = "root";
                    group = "root";
                    permissions = "0600";
                  };
                  "runtime_host_key.pub" = {
                    keyCommand = ["cat" runtimeKeyPubPath];
                    destDir = "/tmp";
                    user = "root";
                    group = "root";
                    permissions = "0644";
                  };
                };
              };

              imports = cfg'.modules ++ [
                inputs.skarabox.nixosModules.skarabox
              ];
            };
        in
          mapAttrs mkNode cfg.hosts
        ));
      };
    in
      (concatMapAttrs mkFlake cfg.hosts);
  };
}
