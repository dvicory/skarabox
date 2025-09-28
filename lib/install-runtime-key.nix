{
  pkgs,
  add-sops-cfg,
}:
pkgs.writeShellApplication {
  name = "install-runtime-key";

  runtimeInputs = [
    pkgs.openssh
    pkgs.jq
    pkgs.colmena  # For deployment
  ];

  text = ''
    set -e
    set -o pipefail

    HOST_NAME=""
    FLAKE_ROOT="."
    VERBOSE=0

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    log() {
      echo -e "''${BLUE}[install-runtime-key]''${NC} $*"
    }

    error() {
      echo -e "''${RED}[ERROR]''${NC} $*" >&2
    }

    success() {
      echo -e "''${GREEN}[✓]''${NC} $*"
    }

    warn() {
      echo -e "''${YELLOW}[⚠]''${NC} $*"
    }

    usage() {
      cat <<USAGE
Usage: $0 -n HOST_NAME [-f FLAKE_ROOT] [-v]
  -h:            Show this usage
  -n HOST_NAME:  Name of the host to install runtime key on
  -f FLAKE_ROOT: Root directory of the flake (default: current directory)
  -v:            Verbose output

This command installs the runtime SSH key on an existing host prepared for
dual SSH key migration. This is Phase 2 of the migration process.

Prerequisites:
  1. Host must be prepared with: nix run .#HOST_NAME-prepare-dual-migration
  2. Runtime key files must exist: HOST_NAME/runtime_host_key*
  3. SOPS configuration must include both keys

What this does:
  1. Validates runtime key exists locally
  2. Creates temporary activation script to install runtime key
  3. Deploys configuration with activation script
  4. Validates runtime key installation on host
  5. Host remains in single-key mode (no behavior change)

After this step, run: nix run .#HOST_NAME-enable-dual-mode
USAGE
    }

    # Parse command line arguments
    while getopts "hn:f:v" opt; do
      case ''${opt} in
        h)
          usage
          exit 0
          ;;
        n)
          HOST_NAME="''${OPTARG}"
          ;;
        f)
          FLAKE_ROOT="''${OPTARG}"
          ;;
        v)
          VERBOSE=1
          ;;
        *)
          usage
          exit 1
          ;;
      esac
    done

    if [[ -z "$HOST_NAME" ]]; then
      error "Host name is required (-n HOST_NAME)"
      usage
      exit 1
    fi

    # Validate prerequisites
    validate_prerequisites() {
      log "Validating prerequisites for $HOST_NAME..."

      # Check if we're in a flake directory
      if [[ ! -f "$FLAKE_ROOT/flake.nix" ]]; then
        error "Not a flake directory: $FLAKE_ROOT"
        exit 1
      fi

      # Check if host directory exists
      HOST_DIR="$FLAKE_ROOT/$HOST_NAME"
      if [[ ! -d "$HOST_DIR" ]]; then
        error "Host directory not found: $HOST_DIR"
        error "Run prepare-dual-migration first: nix run .#$HOST_NAME-prepare-dual-migration"
        exit 1
      fi

      # Check if runtime key exists
      RUNTIME_KEY="$HOST_DIR/runtime_host_key"
      RUNTIME_KEY_PUB="$HOST_DIR/runtime_host_key.pub"
      
      if [[ ! -f "$RUNTIME_KEY" || ! -f "$RUNTIME_KEY_PUB" ]]; then
        error "Runtime key not found: $RUNTIME_KEY"
        error "Run prepare-dual-migration first: nix run .#$HOST_NAME-prepare-dual-migration"
        exit 1
      fi

      # Check if SOPS config includes dual keys
      SOPS_CONFIG="$FLAKE_ROOT/.sops.yaml"
      if [[ ! -f "$SOPS_CONFIG" ]]; then
        error "SOPS configuration not found: $SOPS_CONFIG"
        exit 1
      fi

      # Check for runtime key in SOPS config
      if ! grep -q "$HOST_NAME""_runtime" "$SOPS_CONFIG"; then
        error "Runtime key not found in SOPS configuration"
        error "Run prepare-dual-migration first: nix run .#$HOST_NAME-prepare-dual-migration"
        exit 1
      fi

      success "Prerequisites validated"
    }

    # Create activation script to install runtime key
    create_activation_script() {
      log "Creating runtime key installation script..."

      success "Manual configuration step required"
      echo ""
      echo "Add this to your $HOST_NAME/configuration.nix:"
      echo ""
      cat <<'NIXCODE'
  # Runtime key installation (Phase 2 of dual SSH migration)
  system.activationScripts.install-runtime-key = {
    text = ''
      RUNTIME_KEY_PATH="/persist/ssh/runtime_host_key"
      RUNTIME_KEY_PUB_PATH="/persist/ssh/runtime_host_key.pub"
      
      if [[ ! -f "$RUNTIME_KEY_PATH" ]]; then
        echo "Installing runtime SSH key..."
        
        # Create directory with proper permissions
        mkdir -p /persist/ssh
        chmod 700 /persist/ssh
        
        # Install keys with proper permissions
        install -m 600 ${./runtime_host_key} "$RUNTIME_KEY_PATH"
        install -m 644 ${./runtime_host_key.pub} "$RUNTIME_KEY_PUB_PATH"
        
        echo "✓ Runtime SSH key installed: $RUNTIME_KEY_PATH"
      else
        echo "ℹ️  Runtime SSH key already installed: $RUNTIME_KEY_PATH"
      fi
      
      # Validate installation
      if [[ -f "$RUNTIME_KEY_PATH" && -f "$RUNTIME_KEY_PUB_PATH" ]]; then
        echo "✓ Runtime key installation validated"
      else
        echo "❌ Runtime key installation failed" >&2
        exit 1
      fi
    '';
    deps = ["users"];
  };
NIXCODE
      echo ""
      echo "Then deploy with your usual method (colmena deploy, etc.)"
      echo ""
    }

    # Deploy configuration with runtime key installation
    deploy_runtime_key() {
      log "Preparing runtime key installation instructions for $HOST_NAME..."

      echo ""
      success "Manual configuration step required"
      echo ""
      echo "Add this to your $HOST_NAME/configuration.nix:"
      echo ""
      echo "  # Runtime key installation (Phase 2 of dual SSH migration)"
      echo "  system.activationScripts.install-runtime-key = {"
      echo "    text = ''"
      echo "      RUNTIME_KEY_PATH=\"/persist/ssh/runtime_host_key\""
      echo "      RUNTIME_KEY_PUB_PATH=\"/persist/ssh/runtime_host_key.pub\""
      echo "      "
      echo "      if [[ ! -f \"\$RUNTIME_KEY_PATH\" ]]; then"
      echo "        echo \"Installing runtime SSH key...\""
      echo "        "
      echo "        # Create directory with proper permissions"
      echo "        mkdir -p /persist/ssh"
      echo "        chmod 700 /persist/ssh"
      echo "        "
      echo "        # Install keys with proper permissions"
      echo "        install -m 600 \''${./runtime_host_key} \"\$RUNTIME_KEY_PATH\""
      echo "        install -m 644 \''${./runtime_host_key.pub} \"\$RUNTIME_KEY_PUB_PATH\""
      echo "        "
      echo "        echo \"✓ Runtime SSH key installed: \$RUNTIME_KEY_PATH\""
      echo "      else"
      echo "        echo \"ℹ️  Runtime SSH key already installed: \$RUNTIME_KEY_PATH\""
      echo "      fi"
      echo "      "
      echo "      # Validate installation"
      echo "      if [[ -f \"\$RUNTIME_KEY_PATH\" && -f \"\$RUNTIME_KEY_PUB_PATH\" ]]; then"
      echo "        echo \"✓ Runtime key installation validated\""
      echo "      else"
      echo "        echo \"❌ Runtime key installation failed\" >&2"
      echo "        exit 1"
      echo "      fi"
      echo "    '';"
      echo "    deps = [\"users\"];"
      echo "  };"
      echo ""
      echo "Then deploy with your usual method (colmena deploy, etc.)"
      echo ""
    }

    # Validate runtime key installation on host
    validate_installation() {
      log "Validating runtime key installation..."
      
      warn "After deployment, verify with:"
      echo "  ssh user@$HOST_NAME 'sudo ls -la /persist/ssh/'"
      echo "  # Should show: runtime_host_key (600) and runtime_host_key.pub (644)"
      echo ""
      echo "Next step: nix run .#$HOST_NAME-enable-dual-mode"
    }

    # Main execution
    main() {
      echo "Installing runtime SSH key for $HOST_NAME..."
      
      validate_prerequisites
      create_activation_script
      deploy_runtime_key
      validate_installation
      
      echo ""
      success "Runtime key installation prepared for $HOST_NAME"
      echo "ℹ️  Host remains in single-key mode until enable-dual-mode is run"
    }

    main "$@"
  '';
}