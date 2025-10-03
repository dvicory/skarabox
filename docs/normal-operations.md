# Normal Operations {#normal-operations}

All commands are prefixed by the hostname, allowing to handle multiple hosts.

## Decrypt `root` pool after boot {#decrypt-root}

   ```bash
   $ nix run .#myskarabox-unlock
   ```

   The connection will then disconnect automatically with no message.
   This is normal behavior.

## SSH in {#ssh}

   ```bash
   $ nix run .#myskarabox-ssh
   ```

## Reboot {#reboot}

   ```bash
   $ nix run .#myskarabox-ssh sudo reboot
   ```

   You will then be required to decrypt the hard drives upon reboot as explained above.

## Deploy an Update {#deploy-update}

   Modify the [./configuration.nix](@REPO@/template/myskarabox/configuration.nix) file then run one of the following snippets:

   To deploy with [deploy-rs](https://github.com/serokell/deploy-rs),
   first import the flake module `skarabox.flakeModules.deploy-rs` as shown in the template [flake.nix][] then:
   ```bash
   $ nix run .#deploy-rs
   ```

   [flake.nix]: @REPO@/template/flake.nix

   To deploy with [colmena](https://github.com/zhaofengli/colmena),
   first import the flake module `skarabox.flakeModules.colmena` as shown in the template [flake.nix][] then:
   ```bash
   $ nix run .#colmena apply
   ```

   Specific options for deploy-rs or colmena can be added by appending
   a double dash followed by the arguments, like so:

   ```bash
   $ nix run .#colmena apply -- --on myskarabox
   ```

## Update dependencies {#update-dependencies}

   ```bash
   $ nix flake update
   $ nix run .#deploy-rs
   ```

   To pin Skarabox to the latest release, edit the [flake.nix][]
   and replace `?ref=<oldversion>` with `?ref=@VERSION@`,
   then run:
   
   ```bash
   $ nix flake update skarabox
   ```

## Edit secrets {#edit-secrets}

   ```bash
   $ nix run .#sops ./myskarabox/secrets.yaml
   ```

## Add other hosts {#add-host}

   ```bash
   $ nix run .#gen-new-host otherhost.
   ```

   and copy needed config in [flake.nix][].

## Migrate to dual host keys {#migrate-dual-keys}

   ::: {.warning}
   **Security Warning:** Single host key hosts are vulnerable to physical attacks. If someone gains physical access to your server, they can extract the `/boot/host_key` and decrypt all your secrets (passwords, API keys, etc.). Migrate to dual host keys to safeguard your user data at rest.
   :::

   Upgrade existing hosts from single host key to dual host key architecture. This separates the initrd key from your administrative secrets, protecting SOPS-encrypted data from physical attacks. **Note:** New hosts created with `gen-new-host` use dual host keys by default.

   ```bash
   $ nix run .#myskarabox-prepare-dual-migration  # Generate runtime keys & update SOPS
   $ nix run .#myskarabox-install-runtime-key     # Install on target
   ```
   
   Update `myskarabox/configuration.nix` to switch SOPS to runtime key:
   ```nix
   sops.age.sshKeyPaths = [
     "/persist/etc/ssh/ssh_host_ed25519_key"   # Switch from /boot/host_key
   ];
   ```
   
   Update `flake.nix` to enable dual host key mode:
   ```nix
   skarabox.hosts.myskarabox = {
     # ... existing config
     runtimeHostKeyPub = ./myskarabox/runtime_host_key.pub;
   };
   ```
   
   Then regenerate known_hosts, deploy, and cleanup:
   ```bash
   $ nix run .#myskarabox-gen-knownhosts-file  # Update for dual host keys
   $ nix run .#deploy-rs                       # Apply dual host key config
   $ age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age < myskarabox/host_key.pub)
   $ nix run .#sops -- -r -i --rm-age "$age_key" myskarabox/secrets.yaml
   ```
   
   **Important:** After migration, rotate the boot key (see below) to protect against git history attacks where old secrets could be decrypted with a stolen boot key.

## Rotate host key {#rotate-host-key}

   **For single host key hosts (legacy):**
   ```bash
   $ ssh-keygen -f ./myskarabox/host_key
   $ nix run .#add-sops-cfg -- -o .sops.yaml alias myskarabox $(ssh-to-age -i ./myskarabox/host_key.pub)
   $ nix run .#sops -- updatekeys ./myskarabox/secrets.yaml
   $ nix run .#myskarabox-gen-knownhosts-file
   $ nix run .#deploy-rs
   ```

   **For dual host key hosts:**
   ```bash
   # Rotate initrd key (boot unlock only - uses secure block-level wipe)
   $ ssh-keygen -t ed25519 -N "" -f ./myskarabox/host_key
   $ nix run .#myskarabox-rotate-initrd-key  # Securely wipes boot partition
   $ nix run .#myskarabox-gen-knownhosts-file
   ```

   **Rotate runtime key** (SOPS secrets - only if compromised):
   ```bash
   $ ssh-keygen -t ed25519 -N "" -f ./myskarabox/runtime_host_key
   $ nix run .#add-sops-cfg -- -o .sops.yaml alias myskarabox_runtime $(ssh-to-age -i ./myskarabox/runtime_host_key.pub)
   $ nix run .#sops -- updatekeys ./myskarabox/secrets.yaml
   $ nix run .#myskarabox-gen-knownhosts-file
   $ nix run .#deploy-rs
   ```
