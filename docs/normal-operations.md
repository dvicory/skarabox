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

## Enable Key Separation {#enable-key-separation}

   ::: {.warning}
   **Security Warning:** Single-key hosts are vulnerable to physical attacks. If someone gains physical access to your server, they can extract the `/boot/host_key` and decrypt all your secrets (passwords, API keys, etc.). Enable key separation to safeguard your user data at rest.
   :::

   Upgrade existing hosts to separated-key architecture. This separates the boot key from your administrative secrets, protecting SOPS-encrypted data from physical attacks. The runtime key is stored in the encrypted ZFS pool, making it inaccessible until boot unlock. **Note:** New hosts created with `gen-new-host` use separated-key mode by default.

   ```bash
   $ nix run .#myskarabox-enable-key-separation  # Generate runtime keys & update SOPS
   $ nix run .#myskarabox-install-runtime-key    # Install on target
   ```

   The first command generates runtime keys and renames your existing key to `myskarabox_boot`, adding the new runtime key as `myskarabox` (primary). The second command copies the runtime key to the target host.

   Update `myskarabox/configuration.nix` to switch SOPS to runtime key:
   ```nix
   sops.age.sshKeyPaths = [
     "/persist/etc/ssh/ssh_host_ed25519_key"   # Switch from /boot/host_key
   ];
   ```

   Update `flake.nix` to enable separated-key mode:
   ```nix
   skarabox.hosts.myskarabox = {
     # ... existing config
     runtimeHostKeyPub = ./myskarabox/runtime_host_key.pub;
   };
   ```

   Deploy the separated-key configuration:
   ```bash
   $ nix run .#myskarabox-gen-knownhosts-file  # Update for separated keys
   $ nix run .#deploy-rs                       # Switches host to runtime key
   ```

   After successful deployment, complete the migration (see warning below):
   ```bash
   # Remove the boot key (now aliased as myskarabox_boot) from SOPS
   $ age_key=$(nix shell nixpkgs#ssh-to-age -c ssh-to-age < myskarabox/host_key.pub)
   $ nix run .#sops -- -r -i --rm-age "$age_key" myskarabox/secrets.yaml

   # Rotate the boot key to protect against git history attacks (destructive)
   $ nix run .#myskarabox-rotate-boot-key
   $ nix run .#myskarabox-gen-knownhosts-file
   ```

   ::: {.warning}
   **Destructive Operation:** `rotate-boot-key` securely wipes the boot partition with `dd + TRIM` to ensure the old key is unrecoverable. The process backs up boot files to tmpfs, wipes the partition, recreates the filesystem, and reinstalls the bootloader. Requires the host to be accessible via runtime key.
   :::

   These final steps ensure secrets cannot be decrypted with the old boot key, protecting against both physical attacks and git history attacks.

## Rotate host key {#rotate-host-key}

   **For single-key hosts (legacy):**

   ```bash
   $ ssh-keygen -f ./myskarabox/host_key
   $ nix run .#add-sops-cfg -- -o .sops.yaml alias myskarabox $(ssh-to-age -i ./myskarabox/host_key.pub)
   $ nix run .#sops -- updatekeys ./myskarabox/secrets.yaml
   $ nix run .#myskarabox-gen-knownhosts-file
   $ nix run .#deploy-rs
   ```

   **For separated-key hosts:**

   Rotate boot key (necessary to protect against git history attack after migration):
   
   ::: {.warning}
   **Destructive Operation:** This command securely wipes the boot partition with `dd + TRIM` to ensure the old key is unrecoverable. The process backs up boot files to tmpfs, wipes the partition, recreates the filesystem, and reinstalls the bootloader. Requires the host to be accessible via runtime key.
   :::
   
   ```bash
   $ nix run .#myskarabox-rotate-boot-key
   $ nix run .#myskarabox-gen-knownhosts-file
   ```

   Rotate runtime key (only if compromised - affects SOPS secrets):
   ```bash
   $ ssh-keygen -t ed25519 -N "" -f ./myskarabox/runtime_host_key
   $ nix run .#add-sops-cfg -- -o .sops.yaml alias myskarabox $(ssh-to-age -i ./myskarabox/runtime_host_key.pub)
   $ nix run .#sops -- updatekeys ./myskarabox/secrets.yaml
   $ nix run .#myskarabox-gen-knownhosts-file
   $ nix run .#deploy-rs
   ```
