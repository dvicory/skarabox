{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.skarabox;

  inherit (lib) isString mkOption toInt types;

  readAndTrim = f: lib.strings.trim (builtins.readFile f);
  readAsStr = v:
    if lib.isPath v
    then readAndTrim v
    else v;
  readAsInt = v: let
    vStr = readAsStr v;
  in
    if isString vStr
    then toInt vStr
    else vStr;
in {
  options.skarabox = {
    hostname = mkOption {
      description = "Hostname to give to the server.";
      type = types.str;
      default = "skarabox";
    };

    username = mkOption {
      description = "Name given to the admin user on the server.";
      type = types.str;
      default = "skarabox";
    };

    staticNetwork = mkOption {
      description = "Use static IP configuration. If unset, use DHCP.";
      default = null;
      example = lib.literalExpression ''
        {
          ip = "192.168.1.30";
          gateway = "192.168.1.1";
        }
      '';
      type = types.nullOr (types.submodule {
        options = {
          enable = lib.mkEnableOption "Skarabox static IP configuration";
          ip = mkOption {
            type = types.str;
            description = "Static IP to use.";
          };
          gateway = mkOption {
            type = types.str;
            description = "IP Gateway, often same beginning as `ip` and finishing by a `1`: `XXX.YYY.ZZZ.1`.";
          };
          device = mkOption {
            description = ''
              Device for which to configure the IP address for.

              Either pass the device name directly if you know it, like "ens3".
              Or configure the `deviceName` option to get the first device name
              matching that prefix from the facter.json report.
            '';
            default = {namePrefix = "en";};
            type = with types;
              oneOf [
                str
                (submodule {
                  options = {
                    namePrefix = mkOption {
                      type = str;
                      description = "Name prefix as it appears in the facter.json report. Used to distinguish between wifi and ethernet.";
                      default = "en";
                      example = "wl";
                    };
                  };
                })
              ];
          };
          deviceName = mkOption {
            description = ''
              Result of applying match pattern from `.device` option
              or the string defined in `.device` option.
            '';
            readOnly = true;
            internal = true;
            default = let
              cfg' = cfg.staticNetwork;

              network_interfaces = config.facter.report.hardware.network_interface;

              firstMatchingDevice = builtins.head (builtins.filter (lib.hasPrefix "en") (lib.flatten (map (x: x.unix_device_names) network_interfaces)));
            in
              if isString cfg'.device
              then cfg'.device
              else firstMatchingDevice;
          };
        };
      });
    };

    disableNetworkSetup = mkOption {
      description = ''
        If set to false, completely disable network setup by Skarabox.

        Make sure you can still ssh to the server.
      '';
      type = types.bool;
      default = false;
    };

    hashedPasswordFile = mkOption {
      description = "Contains hashed password for the admin user.";
      type = types.str;
    };

    facter-config = lib.mkOption {
      description = ''
        nixos-facter config file.
      '';
      type = lib.types.path;
    };

    hostId = mkOption {
      type = with types; oneOf [str path];
      description = ''
        8 characters unique identifier for this server. Generate with `uuidgen | head -c 8`.
      '';
      apply = readAsStr;
    };

    sshPort = mkOption {
      type = with types; oneOf [int str path];
      default = 22;
      description = ''
        Port the SSH daemon listens to.
      '';
      apply = readAsInt;
    };

    sshAuthorizedKey = mkOption {
      type = with types; oneOf [str path];
      description = ''
        Public SSH key used to connect on boot to decrypt the root pool.
      '';
      apply = readAsStr;
    };

    # Dual SSH key architecture support
    useDualSshKeys = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Force enable dual SSH key architecture.

        NOTE: Dual keys are the default for new hosts and are auto-detected based on SOPS configuration.
        If SOPS is configured to use '${cfg.runtimeSshKeyPath}', dual mode is automatically enabled.
        Set this to true only if you need to override auto-detection for a custom setup.
      '';
    };

    runtimeSshKeyPath = mkOption {
      type = types.str;
      default = "/persist/ssh/runtime_host_key";
      description = ''
        Path to runtime SSH private key (dual key mode only).
        Used for administrative SSH access and SOPS secret decryption.
      '';
    };
  };

  config = let
    # Auto-detect dual SSH key mode based on SOPS configuration
    # Default to dual mode if SOPS uses runtime key, or if explicitly enabled
    # Legacy hosts with SOPS using /boot/host_key remain in single key mode
    isDualSshMode =
      cfg.useDualSshKeys
      || (
        config.sops ? age
        && config.sops.age ? sshKeyPaths
        && builtins.elem cfg.runtimeSshKeyPath config.sops.age.sshKeyPaths
      );
  in {
    assertions = [
      {
        assertion = cfg.staticNetwork == null -> config.boot.initrd.network.udhcpc.enable;
        message = ''
          If DHCP is disabled and an IP is not set, the box will not be reachable through the network on boot and you will not be able to enter the passphrase through SSH.

          To fix this error, either set config.boot.initrd.network.udhcpc.enable = true or give an IP to skarabox.staticNetwork.ip.
        '';
      }
    ];

    facter.reportPath = lib.mkIf (builtins.pathExists cfg.facter-config) cfg.facter-config;

    networking.hostName = cfg.hostname;
    networking.hostId = cfg.hostId;

    systemd.network = lib.mkIf (!cfg.disableNetworkSetup) (
      if cfg.staticNetwork == null
      then {
        enable = true;
        networks."10-lan" = {
          matchConfig.Name = "en*";
          networkConfig.DHCP = "ipv4";
          linkConfig.RequiredForOnline = true;
        };
      }
      else {
        enable = true;
        networks."10-lan" = {
          matchConfig.Name = "en*";
          address = [
            "${cfg.staticNetwork.ip}/24"
          ];
          routes = [
            {Gateway = cfg.staticNetwork.gateway;}
          ];
          linkConfig.RequiredForOnline = true;
        };
      }
    );

    powerManagement.cpuFreqGovernor = "performance";

    nix.settings.trusted-users = [cfg.username];
    nix.settings.experimental-features = ["nix-command" "flakes"];
    nix.settings.auto-optimise-store = true;
    nix.gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };

    # See https://www.freedesktop.org/software/systemd/man/journald.conf.html#SystemMaxUse=
    services.journald.extraConfig = ''
      SystemMaxUse=2G
      SystemKeepFree=4G
      SystemMaxFileSize=100M
      MaxFileSec=day
    '';

    # hashedPasswordFile only works if users are not mutable.
    users.mutableUsers = false;
    users.users.${cfg.username} = {
      isNormalUser = true;
      extraGroups = ["wheel"];
      inherit (cfg) hashedPasswordFile;
      openssh.authorizedKeys.keys = [cfg.sshAuthorizedKey];
    };

    security.sudo.extraRules = [
      {
        users = [cfg.username];
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    environment.systemPackages = [
      pkgs.vim
      pkgs.curl
      pkgs.nixos-facter
    ];

    services.openssh = {
      enable = true;
      settings = {
        PermitRootLogin = "no";
        PasswordAuthentication = false;
      };
      ports = [cfg.sshPort];

      # Architecture-aware host key configuration
      # Both keys are managed externally by skarabox, not by NixOS
      hostKeys = lib.mkForce []; # Disable NixOS key management

      extraConfig =
        if isDualSshMode
        then ''
          HostKey ${cfg.runtimeSshKeyPath}
        ''
        else ''
          HostKey /boot/host_key
        '';
    };

    # Dual SSH key support infrastructure
    systemd.tmpfiles.rules = lib.optionals isDualSshMode [
      "d /persist/ssh 0700 root root -"
    ];

    # Runtime key installation during system activation
    system.activationScripts.install-runtime-ssh-key = lib.mkIf isDualSshMode {
      text = ''
        if [ -f /tmp/runtime_host_key ] && [ ! -f ${cfg.runtimeSshKeyPath} ]; then
          echo "Skarabox: Installing runtime SSH key..."
          install -D -m 600 /tmp/runtime_host_key ${cfg.runtimeSshKeyPath}
          install -D -m 644 /tmp/runtime_host_key.pub ${cfg.runtimeSshKeyPath}.pub
          rm -f /tmp/runtime_host_key /tmp/runtime_host_key.pub
          echo "Skarabox: Runtime SSH key installed"
        fi
      '';
      deps = ["users" "setupSecrets"];
    };

    # Informational warnings about detected architecture
    warnings =
      [
        (
          if isDualSshMode
          then "Skarabox: Using dual SSH key architecture (default for new hosts)"
          else "Skarabox: Using single SSH key architecture (legacy mode)"
        )
      ]
      ++ lib.optionals isDualSshMode [
        ''
          Dual SSH key security model:
          - Initrd key (/boot/host_key): Boot unlock only, vulnerable to physical access
          - Runtime key (${cfg.runtimeSshKeyPath}): Admin access and SOPS, stored securely
        ''
      ];

    system.stateVersion = "23.11";
  };
}
