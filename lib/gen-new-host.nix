{
  pkgs,
  add-sops-cfg,
}:
pkgs.writeShellApplication {
  name = "gen-new-host";

  runtimeInputs  = [
    add-sops-cfg
    pkgs.gnused
    pkgs.mkpasswd
    pkgs.openssh
    pkgs.openssl
    pkgs.sops
    pkgs.ssh-to-age
    pkgs.util-linux
  ];

  text = ''
    set -e
    set -o pipefail

    yes=0
    mkpasswdargs=
    verbose=
    dual_keys=1  # Default to dual keys for new hosts (better security)

    usage () {
      cat <<USAGE
Usage: $0 [-h] [-y] [-s] [-v] [--single-key] -n HOSTNAME

  The only required argument, HOSTNAME, is the hostname
  you want to give to the new host. It will also be used
  as a nickname for the host in the nix configuration.

  -h:        Shows this usage
  -y:        Answer yes to all questions
  -s:        Take user password from stdin. Only useful
              in scripts.
  -v:        Shows what commands are being run.
  --single-key: Use legacy single host key mode (less secure).
              Creates only one key used for both boot unlock and
              administrative access. Key stored unencrypted on /boot
              partition enables SOPS secret compromise via physical access.
              Consider dual-key mode (default) for better security.
  -n:        Generate files for this hostname.

  By default, dual host keys are generated for enhanced security:
  - initrd key: /boot/host_key (vulnerable but limited scope)
  - runtime key: /persist/etc/ssh/ssh_host_ed25519_key (secure, encrypted storage)

  Runtime key uses standard OpenSSH path for impermanence compatibility.
  The system auto-detects which mode to use based on SOPS configuration.
  Use --single-key for legacy mode (less secure).
USAGE
    }

    while getopts "hysv-:n:" o; do
      case "''${o}" in
        h)
          usage
          exit 0
          ;;
        y)
          yes=1
          ;;
        s)
          mkpasswdargs=-s
          ;;
        v)
          verbose=1
          ;;
        n)
          hostname="''${OPTARG}"
          ;;
        -)
          case "''${OPTARG}" in
            single-key)
              dual_keys=0
              ;;
            *)
              echo "Unknown option: --''${OPTARG}" >&2
              usage
              exit 1
              ;;
          esac
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done
    shift $((OPTIND-1))

    # If hostname wasn't set via -n flag, try to get it from positional argument
    if [ -z "$hostname" ]; then
      hostname=$1
    fi

    if [ -z "$hostname" ]; then
      echo "Please give a hostname. Add -h for usage."
      exit 1
    fi

    e () {
      echo -e "\e[1;31mSKARABOX:\e[0m \e[1;0m$*\e[0m"
    }

    # From https://stackoverflow.com/a/29436423/1013628
    yes_or_no () {
      while true; do
        echo -ne "\e[1;31mSKARABOX:\e[0m "
        if [ "$yes" -eq 1 ]; then
          echo "$* Forced yes"
          return 0
        else
          read -rp "$* [y/n]: " yn
          case $yn in
            [Yy]*) return 0 ;;
            [Nn]*) echo "Aborting" ; exit 2 ;;
          esac
        fi
      done
    }

    if [ -n "$verbose" ]; then
      set -x
    fi

    e "This script will create a new folder ./$hostname and initiate the template and secrets to manage a host using Skarabox."
    yes_or_no "Most of the steps are automatic but there are some instructions you'll need to follow manually at the end, continue?"

    if [ -e "$hostname" ]; then
      e "Cannot create $hostname folder as it already exists. Please remove it or use another hostname."
      exit 1
    fi

    mkdir -p "$hostname"

    e "[1/5] Generating $hostname/configuration.nix"
    cp ${../template/myskarabox/configuration.nix} "$hostname/configuration.nix"
    sed -i "s/myskarabox/$hostname/g" "$hostname/configuration.nix"

    # Template is configured for dual-key mode by default
    # Only patch for single-key mode if requested
    if [ "$dual_keys" -eq 0 ]; then
      # Patch SOPS to use initrd key instead of runtime key
      sed -i 's|/persist/etc/ssh/ssh_host_ed25519_key|/boot/host_key|' "$hostname/configuration.nix"

      # Update comment to reflect single-key mode (preserving indentation)
      sed -i 's/# Dual key mode:.*/# Single host key mode (legacy - less secure)/' "$hostname/configuration.nix"

      e "Warning: Configuration uses legacy single host key mode (less secure)"
    else
      e "Configuration uses dual host key mode (enhanced security - OpenSSH standard path)"
    fi

    e "[2/5] Generating host keys and admin SSH key"
    host_key="./$hostname/host_key"
    host_key_pub="$host_key.pub"
    e "Generating server host key in $host_key and $host_key.pub..."
    ssh-keygen -t ed25519 -N "" -f "$host_key" && chmod 600 "$host_key"

    # Generate runtime key if dual keys enabled
    if [ "$dual_keys" -eq 1 ]; then
      runtime_key="./$hostname/runtime_host_key"
      runtime_key_pub="$runtime_key.pub"
      e "Generating runtime host key in $runtime_key and $runtime_key.pub..."
      ssh-keygen -t ed25519 -N "" -f "$runtime_key" && chmod 600 "$runtime_key"
    fi

    ssh_key="./$hostname/ssh"
    e "Generating ssh key in $ssh_key and $ssh_key.pub..."
    ssh-keygen -t ed25519 -N "" -f "$ssh_key" && chmod 600 "$ssh_key"

    hostid="./$hostname/hostid"
    e "Generating hostid in $hostid..."
    uuidgen | head -c 8 > "$hostid"

    e "[3/5] Configuring SOPS encryption"
    sops_cfg="./.sops.yaml"
    secrets="$hostname/secrets.yaml"
    e "Adding host key in $sops_cfg..."

    # Use runtime key for SOPS if dual keys enabled, otherwise use initrd key
    if [ "$dual_keys" -eq 1 ]; then
      sops_key_pub="$runtime_key_pub"
      e "Using secure runtime key for SOPS encryption (dual key mode)"
    else
      sops_key_pub="$host_key_pub"
      e "Using initrd host key for SOPS encryption (single key mode)"
    fi

    host_age_key="$(ssh-to-age -i "$sops_key_pub")"
    add-sops-cfg -o "$sops_cfg" alias "$hostname" "$host_age_key"
    add-sops-cfg -o "$sops_cfg" path-regex main "$secrets"
    add-sops-cfg -o "$sops_cfg" path-regex "$hostname" "$secrets"

    e "[4/5] Initializing secrets"
    sops_key="./sops.key"
    export SOPS_AGE_KEY_FILE=$sops_key
    e "Generating sops secrets file $secrets..."
    echo "tmp_secret: a" > "$secrets"
    sops encrypt -i "$secrets"

    e "Generating initial password for user in $secrets under $hostname/user/hashedPassword"
    sops set "$secrets" \
      "['$hostname']['user']['hashedPassword']" \
      "\"$(mkpasswd $mkpasswdargs)\""

    e "Generating root pool passphrase in $secrets under $hostname/disks/rootPassphrase"
    sops set "$secrets" \
      "['$hostname']['disks']['rootPassphrase']" \
      "\"$(openssl rand -hex 64)\""

    e "Generating data pool passphrase in $secrets under $hostname/disks/dataPassphrase"
    sops set "$secrets" \
      "['$hostname']['disks']['dataPassphrase']" \
      "\"$(openssl rand -hex 64)\""

    sops unset "$secrets" \
      "['tmp_secret']"

    e "[5/5] Setup complete - next steps"
    e "You will need to fill out the ./$hostname/ip and ./$hostname/system file and generate ./$hostname/known_hosts."
    e "Optionally, adjust the ./$hostname/ssh_port and ./$hostname/ssh_boot_port if you want to."

    if [ "$dual_keys" -eq 1 ]; then
      echo ""
      e "DUAL HOST KEYS GENERATED (DEFAULT):"
      e "  Initrd key (vulnerable):  ./$hostname/host_key"
      e "  Runtime key (secure):     ./$hostname/runtime_host_key"
      echo ""
      e "ENHANCED SECURITY:"
      e "  - SOPS secrets encrypted with SECURE runtime key"
      e "  - Administrative access uses SECURE runtime key"
      e "  - Boot unlock limited to vulnerable initrd key only"
      echo ""
      e "Your host is ready for deployment with dual host key security!"
      e "System auto-detects dual mode from SOPS configuration"
    else
      echo ""
      e "LEGACY SINGLE KEY MODE:"
      e "  - ALL operations use vulnerable /boot/host_key"
      e "  - Physical access = complete secret compromise"
      e "  - Consider dual key mode for better security"
    fi

    e "Follow the ./README.md for more information and to continue the installation."
  '';
}
