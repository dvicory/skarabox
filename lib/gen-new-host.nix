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
  --single-key: Use legacy single SSH key mode (less secure).
             Creates only one key used for both boot unlock and
             administrative access. Key stored unencrypted on /boot
             partition enables SOPS secret compromise via physical access.
             Consider dual-key mode (default) for better security.
  -n:        Generate files for this hostname.

  By default, dual SSH keys are generated for enhanced security:
  - initrd key: /boot/host_key (vulnerable but limited scope)  
  - runtime key: /persist/ssh/runtime_host_key (secure, encrypted storage)
  
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

    e "Generating $hostname/configuration.nix"
    cp ${../template/myskarabox/configuration.nix} "$hostname/configuration.nix"
    sed -i "s/myskarabox/$hostname/" "$hostname/configuration.nix"
    
    # Update configuration for dual keys if enabled
    if [ "$dual_keys" -eq 1 ]; then
      # Template already configured for dual keys with runtime key SOPS path
      # The system will auto-detect dual mode from SOPS configuration
      sed -i '/skarabox\.hostname = /a\
      # Dual SSH key architecture (auto-detected from SOPS config):\
      # - Initrd key: /boot/host_key (boot unlock only)\
      # - Runtime key: /persist/ssh/runtime_host_key (admin access + SOPS)' "$hostname/configuration.nix"
      
      e "✅ Configuration uses dual SSH key mode (auto-detected)"
    else
      # Update SOPS to use initrd key (system will auto-detect single mode)
      sed -i '/sops\.age = {/,/};/c\
      sops.age = {\
        sshKeyPaths = [ "/boot/host_key" ];\
      };' "$hostname/configuration.nix"
      
      sed -i '/skarabox\.hostname = /a\
      # Single SSH key architecture (auto-detected from SOPS config)' "$hostname/configuration.nix"
      
      e "⚠️  Configuration uses legacy single SSH key mode (less secure)"
    fi

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

    e "You will need to fill out the ./$hostname/ip and ./$hostname/system file and generate ./$hostname/known_hosts."
    e "Optionally, adjust the ./$hostname/ssh_port and ./$hostname/ssh_boot_port if you want to."
    
    if [ "$dual_keys" -eq 1 ]; then
      e ""
      e "🔐 DUAL SSH KEYS GENERATED (DEFAULT):"
      e "   Initrd key (vulnerable):  ./$hostname/host_key"
      e "   Runtime key (secure):     ./$hostname/runtime_host_key"
      e ""
      e "✅ ENHANCED SECURITY:"
      e "   • SOPS secrets encrypted with SECURE runtime key"
      e "   • Administrative access uses SECURE runtime key"
      e "   • Boot unlock limited to vulnerable initrd key only"
      e ""
      e "   Your host is ready for deployment with dual SSH key security!"
      e "   Configuration automatically enables skarabox.dualSshKeys.enable = true"
    else
      e ""
      e "⚠️  LEGACY SINGLE KEY MODE:"
      e "   • ALL operations use vulnerable /boot/host_key"
      e "   • Physical access = complete secret compromise"
      e "   • Consider dual key mode for better security"
    fi
    
    e "Follow the ./README.md for more information and to continue the installation."
  '';

}
