{ pkgs, nixos-anywhere }:
pkgs.writeShellApplication {
  name = "install-on-beacon";

  runtimeInputs = [
    nixos-anywhere
    pkgs.bash
  ];

  text = ''
    usage () {
      cat <<USAGE
    Usage: $0 -i IP -p PORT -f FLAKE -k HOST_KEY_FILE -u USERNAME [-d]

      -h:               Shows this usage
      -i IP:            IP of the target host running the beacon.
      -p PORT:          Port of the target host running the beacon.
      -f FLAKE:         Flake to install on the target host.
      -k HOST_KEY_FILE: SSH key to use as the host identification key.
      -u USERNAME:      Username to connect to the host with.
      -d:               Debug mode - print the nixos-anywhere command before running.
      
      Any additional arguments after the flags will be passed to nixos-anywhere.
    USAGE
    }

    check_empty () {
      if [ -z "$1" ]; then
        echo "$3 must not be empty, pass with flag $2"
      fi
    }

    debug=0

    while getopts "hi:p:f:k:du:" o; do
      case "''${o}" in
        h)
          usage
          exit 0
          ;;
        i)
          ip=''${OPTARG}
          ;;
        p)
          port=''${OPTARG}
          ;;
        f)
          flake=''${OPTARG}
          ;;
        k)
          host_key_file=''${OPTARG}
          ;;
        d)
          debug=1
          ;;
        u)
          username=''${OPTARG}
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done
    shift $((OPTIND-1))

    check_empty "$ip" -i ip
    check_empty "$port" -p port
    check_empty "$flake" -f flake
    check_empty "$host_key_file" -k host_key_file
    check_empty "$username" -u username

    if [ "$debug" -eq 1 ]; then
      echo "Debug: nixos-anywhere command:" >&2
      echo "nixos-anywhere \\" >&2
      echo "  --flake $flake \\" >&2
      echo "  --disk-encryption-keys /tmp/host_key $host_key_file \\" >&2
      echo "  --ssh-port $port \\" >&2
      for arg in "$@"; do
        echo "  $arg \\" >&2
      done
      echo "  $username@$ip" >&2
      echo "" >&2
    fi

    # All remaining arguments are passed to nixos-anywhere
    nixos-anywhere \
      --flake "$flake" \
      --disk-encryption-keys /tmp/host_key "$host_key_file" \
      --ssh-port "$port" \
      "$@" \
      "$username"@"$ip"
  '';
}
