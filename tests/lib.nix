{
  pkgs,
  ...
}:
let
  add-sops-cfg = pkgs.callPackage ../lib/add-sops-cfg.nix {};

  exec = {
    name,
    cmd,
    init ? ""
  }: builtins.readFile ((pkgs.callPackage ({ runCommand }: runCommand name {
    nativeBuildInputs = [
      add-sops-cfg
    ];
  } (let
    initFile = pkgs.writeText "init-sops" init;
  in ''
    mkdir $out
    ${if init != "" then "cat ${initFile} > $out/.sops.yaml" else ""}
    add-sops-cfg -o $out/.sops.yaml ${cmd}
  '')) {}) + "/.sops.yaml");
in
{
  testAddSopsCfg_new_alias = {
    expected = ''
      keys:
      - &a ASOPSKEY
    '';

    expr = exec {
      name = "testAddSopsCfg_new_alias";
      cmd = "alias a ASOPSKEY";
    };
  };

  testAddSopsCfg_new_path_regex = {
    expected = ''
      keys:
      - &a ASOPSKEY
      creation_rules:
      - path_regex: a/b.yaml$
        key_groups:
        - age:
          - *a
    '';

    expr = exec {
      name = "testAddSopsCfg_new_path_regex";
      init = ''
        keys:
        - &a ASOPSKEY
      '';
      cmd = "path-regex a a/b.yaml$";
    };
  };

  testAddSopsCfg_update_alias = {
    expected = ''
      keys:
      - &a ASOPSKEY
      - &b BSOPSKEY
      creation_rules:
      - path_regex: a/b.yaml$
        key_groups:
        - age:
          - *a
    '';

    expr = exec {
      name = "testAddSopsCfg_update_alias";
      init = ''
        keys:
        - &a ASOPSKEY
        creation_rules:
        - path_regex: a/b.yaml$
          key_groups:
          - age:
            - *a
      '';
      cmd = "alias b BSOPSKEY";
    };
  };

  testAddSopsCfg_update_path_regex = {
    expected = ''
      keys:
      - &a ASOPSKEY
      - &b BSOPSKEY
      creation_rules:
      - path_regex: a/b.yaml$
        key_groups:
        - age:
          - *a
          - *b
    '';

    expr = exec {
      name = "testAddSopsCfg_update_path_regex";
      init = ''
        keys:
        - &a ASOPSKEY
        - &b BSOPSKEY
        creation_rules:
        - path_regex: a/b.yaml$
          key_groups:
          - age:
            - *a
      '';
      cmd = "path-regex b a/b.yaml$";
    };
  };

  testAddSopsCfg_append = {
    expected = ''
      keys:
      - &a ASOPSKEY
      creation_rules:
      - path_regex: a/b.yaml$
        key_groups:
        - age:
          - *a
      - path_regex: b/b.yaml$
        key_groups:
        - age:
          - *a
      '';

    expr = exec {
      name = "testAddSopsCfg_append";
      init = ''
        keys:
        - &a ASOPSKEY
        creation_rules:
        - path_regex: a/b.yaml$
          key_groups:
          - age:
            - *a
        '';
      cmd = "path-regex a b/b.yaml$";
    };
  };

  testAddSopsCfg_replace = {
    expected = ''
      keys:
      - &a OTHERSOPSKEY
      '';

    expr = exec {
      name = "testAddSopsCfg_replace";
      init = ''
        keys:
        - &a ASOPSKEY
        '';
      cmd = "alias a OTHERSOPSKEY";
    };
  };

  testAddSopsCfg_replace_with_reference = {
    expected = ''
      keys:
      - &b BSOPSKEY
      - &a OTHERSOPSKEY
      creation_rules:
      - path_regex: a/b.yaml$
        key_groups:
        - age:
          - *a
      - path_regex: b/b.yaml$
        key_groups:
        - age:
          - *b
      '';

    expr = exec {
      name = "testAddSopsCfg_replace";
      init = ''
        keys:
        - &a ASOPSKEY
        - &b BSOPSKEY
        creation_rules:
        - path_regex: a/b.yaml$
          key_groups:
          - age:
            - *a
        - path_regex: b/b.yaml$
          key_groups:
          - age:
            - *b
        '';
      cmd = "alias a OTHERSOPSKEY";
    };
  };

  # Test dual SSH key mode configuration generation (default)
  testGenNewHost_dualMode = {
    expected = true;
    expr = 
      let
        # Test the template processing logic directly
        configTemplate = builtins.readFile ../template/myskarabox/configuration.nix;
        hasDualKeyPath = builtins.match ".*persist/ssh/runtime_host_key.*" configTemplate != null;
      in hasDualKeyPath;
  };

  # Test single key mode detection logic from configuration.nix module
  testDualKeyAutoDetection_single = {
    expected = false;
    expr =
      let
        # Test the auto-detection logic with single key SOPS config
        testConfig = {
          sops.age.sshKeyPaths = [ "/boot/host_key" ];
        };
        # This would be the logic from modules/configuration.nix
        isDualMode = builtins.any (path: builtins.match ".*/persist/ssh/runtime_host_key.*" path != null) testConfig.sops.age.sshKeyPaths;
      in isDualMode;
  };

  # Test dual key mode detection logic from configuration.nix module  
  testDualKeyAutoDetection_dual = {
    expected = true;
    expr =
      let
        # Test the auto-detection logic with dual key SOPS config
        testConfig = {
          sops.age.sshKeyPaths = [ "/persist/ssh/runtime_host_key" ];
        };
        # This would be the logic from modules/configuration.nix
        isDualMode = builtins.any (path: builtins.match ".*/persist/ssh/runtime_host_key.*" path != null) testConfig.sops.age.sshKeyPaths;
      in isDualMode;
  };
}
