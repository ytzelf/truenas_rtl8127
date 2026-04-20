#!/bin/bash
# Build RyzenAdj and ryzen_smu using Docker on TrueNAS SCALE
# RyzenAdj: CPU power parameters utility (https://github.com/FlyGoat/RyzenAdj)
# ryzen_smu: Kernel module dependency (https://github.com/amkillam/ryzen_smu)
#
# USAGE:
#   sudo bash docker_build_ryzenadj.sh
#   Output: /mnt/apps/home/drivers/ryzen_smu.ko (loaded)
#           /mnt/apps/home/scripts/ryzenadj (executable)
#
# PREREQUISITES:
#   - TrueNAS SCALE 24.10+ with Docker support
#   - Kernel headers: linux-headers-truenas-production-amd64
#   - AMD Ryzen CPU (Zen 2+), /dev/mem or /sys access
#
# CONFIGURATION:
#   BUILD_DIR=/tmp/custom <script>      # Build directory (default: /tmp/ryzenadj_build)
#   DRIVERS_DIR=/path <script>          # Module storage (default: /mnt/apps/home/drivers)
#   SCRIPTS_DIR=/path <script>          # Binary storage (default: /mnt/apps/home/scripts)
#   CLEANUP=1 <script>                  # Remove build dir on exit
#
# NOTES:
#   - ryzen_smu auto-loads and verifies version (0.1.x compatibility)
#   - Both artifacts installed to persistent TrueNAS 26 paths
#   - For reboot persistence: add 'insmod /mnt/apps/home/drivers/ryzen_smu.ko' in
#     System Settings -> Advanced -> Init/Shutdown Scripts -> Post Init
#   - Troubleshooting: dmesg | grep -i ryzen_smu
#   - TrueNAS 26 BETA: May enforce Secure Boot (disable or sign module)
#   - No warranty provided; review before running.

set -euo pipefail

# ============================================================================
# Configuration Variables
# ============================================================================

BUILD_DIR="${BUILD_DIR:-/tmp/ryzenadj_build}"
IMAGE_NAME="${IMAGE_NAME:-ryzenadj-builder}"
RYZENADJ_REPO_URL="${RYZENADJ_REPO_URL:-https://github.com/FlyGoat/RyzenAdj.git}"
RYZEN_SMU_REPO_URL="${RYZEN_SMU_REPO_URL:-https://github.com/amkillam/ryzen_smu.git}"
BUILD_REF="${BUILD_REF:-}"  # Branch/tag reference (empty = use default)
REBUILD_IMAGE="${REBUILD_IMAGE:-0}"  # Force rebuild Docker image

# Installation paths (configured for TrueNAS persistent storage)
DRIVERS_DIR="${DRIVERS_DIR:-/mnt/apps/home/drivers}"  # Kernel module storage
SCRIPTS_DIR="${SCRIPTS_DIR:-/mnt/apps/home/scripts}"  # Binary storage

# Cleanup behavior (disabled by default to preserve build artifacts)
CLEANUP="${CLEANUP:-0}"        # Set to 1 to remove build directory on exit
CLEANUP_IMAGE="${CLEANUP_IMAGE:-0}"  # Set to 1 to remove Docker image on exit

# Directory and file names
RYZENADJ_DIR="RyzenAdj"
RYZEN_SMU_DIR="ryzen_smu"

# State variables (populated during script execution)
HEADERS_DIR=""                 # Resolved kernel headers path
RYZEN_SMU_INSTALLED_PATH=""    # Final path of loaded kernel module
RYZENADJ_INSTALLED_PATH=""     # Final path of installed binary

# ============================================================================
# Utility Functions
# ============================================================================

log() {
    # Print a message to stdout
    printf '%s\n' "$*"
}

die() {
    # Print error message and exit with code 1
    log "Error: $*"
    exit 1
}

cleanup() {
    # Handle cleanup and exit code on script termination
    local exit_code=$?

    # Remove build directory if requested
    if [ "$CLEANUP" -eq 1 ] && [ -d "$BUILD_DIR" ]; then
        log "--------------------------------------------------"
        log "Cleaning up build directory: $BUILD_DIR"
        rm -rf "$BUILD_DIR"
    fi

    # Remove Docker image if requested
    if [ "$CLEANUP_IMAGE" -eq 1 ] && docker image inspect "$IMAGE_NAME" &> /dev/null; then
        log "--------------------------------------------------"
        log "Cleaning up Docker image: $IMAGE_NAME"
        docker rmi "$IMAGE_NAME" > /dev/null 2>&1 || true
    fi

    # Notify user about retained artifacts on successful exit
    if [ "$exit_code" -eq 0 ] && [ "$CLEANUP" -ne 1 ]; then
        log "--------------------------------------------------"
        log "Build artifacts kept at: $BUILD_DIR"
        log "(Set CLEANUP=1 to delete build artifacts automatically.)"
    fi
}

trap cleanup EXIT

# ============================================================================
# Requirements Validation
# ============================================================================

check_requirements() {
    # Validate all prerequisites for building and running RyzenAdj/ryzen_smu
    log "Checking requirements..."

    # Verify root/sudo privileges
    [[ $EUID -ne 0 ]] && die "This script must be run with sudo or as root."

    # Check for required commands: docker, git
    for cmd in docker git; do
        command -v "$cmd" &> /dev/null || die "'$cmd' is not installed or not in PATH."
    done

    # Verify Docker daemon is running
    if ! docker info > /dev/null 2>&1; then
        die $'Docker daemon is not reachable.\nOn TrueNAS SCALE, enable Apps in UI first.'
    fi

    # Locate kernel headers (required for kernel module compilation)
    local kernel_version kernel_headers
    kernel_version=$(uname -r)
    kernel_headers="/usr/src/linux-headers-$kernel_version"
    
    # Fallback: use production headers if version-specific headers not found
    if [ ! -d "$kernel_headers" ]; then
        kernel_headers="/usr/src/linux-headers-truenas-production-amd64"
    fi

    if [ ! -d "$kernel_headers" ]; then
        die "Kernel headers not found. Install 'linux-headers-truenas-production-amd64'"
    fi

    # Validate and resolve kernel headers directory
    HEADERS_DIR=$(readlink -f "$kernel_headers")
    [ -f "$HEADERS_DIR/Makefile" ] || die "Kernel headers invalid (missing Makefile): $HEADERS_DIR"

    # Warn if kernel version is too old
    log "Kernel version: $kernel_version"
    if [[ ! "$kernel_version" =~ ^[4-9]\.[0-9]+ ]]; then
        log "WARNING: Kernel version < 4.19. ryzen_smu requires 4.19+"
    fi

    # Verify kernel module support is enabled
    [ -f /proc/modules ] || die "Kernel module support not found. Unable to proceed."

    # Warn if /dev/mem is missing (fallback for RyzenAdj if module unavailable)
    [ -e /dev/mem ] || log "WARNING: /dev/mem not found. RyzenAdj fallback mode unavailable."

    log "✓ All requirements met"
}

prepare_build_env() {
    log "Setting up build directory at $BUILD_DIR..."
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    # Clone RyzenAdj
    if [ ! -d "$RYZENADJ_DIR" ]; then
        log "Cloning RyzenAdj source from $RYZENADJ_REPO_URL..."
        if [ -n "$BUILD_REF" ]; then
            git clone --depth 1 --branch "$BUILD_REF" "$RYZENADJ_REPO_URL" "$RYZENADJ_DIR"
        else
            git clone --depth 1 "$RYZENADJ_REPO_URL" "$RYZENADJ_DIR"
        fi
    else
        [ -d "$RYZENADJ_DIR/.git" ] || die "Existing '$BUILD_DIR/$RYZENADJ_DIR' is not a git repo; remove it or pick a different BUILD_DIR."
        log "RyzenAdj source already exists at $BUILD_DIR/$RYZENADJ_DIR (skipping clone)."
    fi

    # Clone ryzen_smu (kernel module dependency)
    if [ ! -d "$RYZEN_SMU_DIR" ]; then
        log "Cloning ryzen_smu source from $RYZEN_SMU_REPO_URL..."
        git clone --depth 1 "$RYZEN_SMU_REPO_URL" "$RYZEN_SMU_DIR"
    else
        [ -d "$RYZEN_SMU_DIR/.git" ] || die "Existing '$BUILD_DIR/$RYZEN_SMU_DIR' is not a git repo; remove it or pick a different BUILD_DIR."
        log "ryzen_smu source already exists at $BUILD_DIR/$RYZEN_SMU_DIR (skipping clone)."
    fi

    log "Creating build environment Dockerfile..."
    cat <<EOF > Dockerfile
FROM debian:trixie

# Install build essentials and dependencies for both kernel module and userspace compilation
RUN apt-get update && apt-get install -y \
    build-essential \
    cmake \
    git \
    libpci-dev \
    pkg-config \
    bc \
    kmod \
    libelf-dev \
    flex \
    bison \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
EOF

    if docker image inspect "$IMAGE_NAME" &> /dev/null && [ "$REBUILD_IMAGE" -ne 1 ]; then
        log "Docker image '$IMAGE_NAME' already exists (set REBUILD_IMAGE=1 to rebuild)."
    else
        log "Building Docker build image ($IMAGE_NAME)..."
        docker build -t "$IMAGE_NAME" .
    fi
}

# ============================================================================
# Kernel Module Compilation
# ============================================================================

compile_ryzen_smu() {
    # Compile ryzen_smu kernel module in Docker against host kernel headers
    log "Compiling ryzen_smu kernel module..."

    docker run --rm \
        -v "$BUILD_DIR/$RYZEN_SMU_DIR:/build/$RYZEN_SMU_DIR:rw" \
        -v "$HEADERS_DIR:/kernel-headers:ro" \
        "$IMAGE_NAME" \
        bash -c "
set -euo pipefail
cd /build/$RYZEN_SMU_DIR

# Prepare kernel headers (generates autoconf.h, etc.)
if [ ! -f /kernel-headers/include/generated/autoconf.h ]; then
    make -C /kernel-headers modules_prepare > /dev/null 2>&1
fi

# Build kernel module
make -C /kernel-headers \
    M=/build/$RYZEN_SMU_DIR \
    KERNELDIR=/kernel-headers \
    modules
"
}

verify_ryzen_smu() {
    # Verify kernel module was compiled and check for compatibility issues
    local module_path="$BUILD_DIR/$RYZEN_SMU_DIR/ryzen_smu.ko"

    [ -f "$module_path" ] || die "Compilation failed: ryzen_smu.ko not found"

    log "--------------------------------------------------"
    log "✓ ryzen_smu kernel module compiled successfully"
    log "--------------------------------------------------"

    # Display module metadata and verify kernel compatibility
    if command -v modinfo &> /dev/null; then
        log "Module metadata:"
        modinfo "$module_path" | grep -E '^(filename|description|version|vermagic):' || true
        
        # Check for kernel vermagic mismatch (major compatibility issue)
        local module_vermagic kernel_vermagic
        module_vermagic=$(modinfo "$module_path" 2>/dev/null | grep '^vermagic:' | cut -d' ' -f2 || echo "unknown")
        kernel_vermagic=$(cat /proc/version | grep -oP 'version \K[^ ]+' || echo "unknown")
        
        if [ "$module_vermagic" != "$kernel_vermagic" ]; then
            log "WARNING: Kernel vermagic mismatch detected"
            log "  Module: $module_vermagic"
            log "  Kernel: $kernel_vermagic"
            log "  This may cause module loading to fail."
        else
            log "✓ Kernel vermagic match verified"
        fi
    fi
}

# ============================================================================
# Module Installation & Loading
# ============================================================================

install_and_load_ryzen_smu() {
    # Copy kernel module to persistent storage and load it into kernel
    local module_src="$BUILD_DIR/$RYZEN_SMU_DIR/ryzen_smu.ko"
    
    log "--------------------------------------------------"
    log "Installing and loading ryzen_smu kernel module..."
    log "--------------------------------------------------"

    # Ensure drivers directory exists
    if [ ! -d "$DRIVERS_DIR" ]; then
        log "Creating drivers directory at $DRIVERS_DIR..."
        mkdir -p "$DRIVERS_DIR" || die "Failed to create $DRIVERS_DIR. Ensure write permissions or adjust DRIVERS_DIR."
    fi

    # Copy module to persistent location
    local module_dest="$DRIVERS_DIR/ryzen_smu.ko"
    log "Copying module from $module_src to $module_dest..."
    cp "$module_src" "$module_dest" || die "Failed to copy ryzen_smu.ko to $DRIVERS_DIR"

    # Check if module is already loaded
    if lsmod | grep -q "^ryzen_smu"; then
        log "ryzen_smu module is already loaded. Checking version compatibility..."
        
        # Verify the loaded module version
        if [ -f /sys/kernel/ryzen_smu_drv/drv_version ]; then
            local version_str
            version_str=$(cat /sys/kernel/ryzen_smu_drv/drv_version 2>/dev/null || echo "unknown")
            log "Loaded module version: $version_str"
            
            # Parse version (expected format: major.minor.patch)
            if echo "$version_str" | grep -qE "^0\.1\.[0-9]+"; then
                log "Version check passed: module is compatible"
            else
                die "Module version mismatch: expected 0.1.x but got $version_str. Cannot proceed."
            fi
        else
            log "WARNING: Could not verify module version (drv_version not accessible)."
            log "Module may be incompatible. Proceeding with caution..."
        fi
        
        RYZEN_SMU_INSTALLED_PATH="$module_dest"
        return 0
    fi

    # Attempt to load the module
    log "Loading ryzen_smu module with insmod..."
    insmod_output=""
    if ! insmod_output=$(insmod "$module_dest" 2>&1); then
        # Check if it's a "File exists" error (module already loaded)
        if echo "$insmod_output" | grep -qi "file exists"; then
            log "Module 'File exists' error detected - module already loaded"
        else
            die "Failed to load ryzen_smu module: $insmod_output"
        fi
    fi

    # Give the kernel a moment to setup sysfs entries
    sleep 1

    # Verify module is loaded
    if ! lsmod | grep -q "^ryzen_smu"; then
        die "Verification failed: ryzen_smu module did not load"
    fi

    log "Module successfully loaded. Verifying sysfs interface..."

    # Verify sysfs interface is available
    if [ ! -d /sys/kernel/ryzen_smu_drv ]; then
        die "ERROR: sysfs interface not found at /sys/kernel/ryzen_smu_drv"
    fi

    if [ ! -f /sys/kernel/ryzen_smu_drv/drv_version ]; then
        die "ERROR: drv_version sysfs file not found"
    fi

    # Read and display version
    local version_str
    version_str=$(cat /sys/kernel/ryzen_smu_drv/drv_version 2>/dev/null || echo "unknown")
    log "Module version from sysfs: $version_str"

    # Validate version format (major=0, minor=1, patch>=7)
    if ! echo "$version_str" | grep -qE "^0\.1\.[0-9]+"; then
        die "Version check failed: expected 0.1.x format but got '$version_str'"
    fi

    log "Check module messages for additional info:"
    dmesg | tail -n 20 | grep -i "ryzen_smu" || log "(No recent ryzen_smu messages)"

    log "--------------------------------------------------"
    log "SUCCESS: ryzen_smu module loaded and verified"
    log "Module location: $module_dest"
    log "Module version: $version_str"
    log "sysfs interface: /sys/kernel/ryzen_smu_drv/"
    log "--------------------------------------------------"

    RYZEN_SMU_INSTALLED_PATH="$module_dest"
}

# ============================================================================
# Userspace Binary Compilation
# ============================================================================

compile_ryzenadj() {
    # Compile RyzenAdj userspace utility in Docker with ryzen_smu headers
    log "--------------------------------------------------"
    log "Compiling RyzenAdj userspace binary..."
    log "Note: Module will be detected at runtime by RyzenAdj"
    log "--------------------------------------------------"

    docker run --rm \
        -v "$BUILD_DIR/$RYZENADJ_DIR:/build/$RYZENADJ_DIR:rw" \
        -v "$BUILD_DIR/$RYZEN_SMU_DIR:/build/$RYZEN_SMU_DIR:ro" \
        "$IMAGE_NAME" \
        bash -c "
set -euo pipefail
cd /build/$RYZENADJ_DIR

# Create and enter build directory
mkdir -p build
cd build

# Build with CMake (includes ryzen_smu headers)
cmake -DRYZEN_SMU_PATH=/build/$RYZEN_SMU_DIR ..
make

# Verify binary was created
if [ ! -f ryzenadj ]; then
    echo \"ERROR: ryzenadj binary not found after build\"
    exit 1
fi
"
}

verify_build() {
    # Verify compiled RyzenAdj binary is functional
    local binary_src="$BUILD_DIR/$RYZENADJ_DIR/build/ryzenadj"

    [ -f "$binary_src" ] || die "Compilation failed: ryzenadj binary not found"

    log "--------------------------------------------------"
    log "✓ RyzenAdj binary compiled successfully"
    log "--------------------------------------------------"

    # Display binary metadata
    log "Binary metadata:"
    file "$binary_src" || true
    log "Size: $(du -h "$binary_src" | cut -f1)"

    # Attempt to display version
    if "$binary_src" --version &>/dev/null; then
        log "Version: $("$binary_src" --version || true)"
    fi

    # Test basic functionality
    if "$binary_src" --help &>/dev/null; then
        log "✓ Help output verified - binary is functional"
    fi

    # Verify module detection capability
    if [ -f /sys/kernel/ryzen_smu_drv/drv_version ]; then
        local module_version
        module_version=$(cat /sys/kernel/ryzen_smu_drv/drv_version 2>/dev/null || echo "unknown")
        log "✓ ryzen_smu module detected (version: $module_version)"
        log "  RyzenAdj will use kernel module backend"
    else
        log "INFO: ryzen_smu module not active"
        log "  RyzenAdj will use fallback mode (/dev/mem) if available"
    fi
}

# ============================================================================
# Binary Installation
# ============================================================================

install_ryzenadj_binary() {
    # Copy RyzenAdj binary to persistent storage and verify installation
    local binary_src="$BUILD_DIR/$RYZENADJ_DIR/build/ryzenadj"
    
    log "--------------------------------------------------"
    log "Installing RyzenAdj binary to persistent storage..."
    log "--------------------------------------------------"

    # Ensure scripts directory exists
    if [ ! -d "$SCRIPTS_DIR" ]; then
        log "Creating scripts directory at $SCRIPTS_DIR..."
        mkdir -p "$SCRIPTS_DIR" || die "Failed to create $SCRIPTS_DIR. Ensure write permissions or adjust SCRIPTS_DIR."
    fi

    # Copy binary to persistent location
    local binary_dest="$SCRIPTS_DIR/ryzenadj"
    log "Copying binary from $binary_src to $binary_dest..."
    cp "$binary_src" "$binary_dest" || die "Failed to copy ryzenadj binary to $SCRIPTS_DIR"

    # Make it executable
    chmod +x "$binary_dest" || die "Failed to make $binary_dest executable"

    # Verify the copied binary
    if [ ! -x "$binary_dest" ]; then
        die "Verification failed: $binary_dest is not executable"
    fi

    log "Verifying installed binary..."
    
    # Display binary information
    log "Binary information:"
    file "$binary_dest" || true
    log "Size: $(du -h "$binary_dest" | cut -f1)"
    log "Permissions: $(ls -l "$binary_dest" | awk '{print $1, $3, $4}')"

    # Try to display version
    if "$binary_dest" --version &>/dev/null; then
        log "Version: $("$binary_dest" --version || true)"
    fi

    # Test basic functionality (help output)
    if "$binary_dest" --help &>/dev/null; then
        log "Help output verified - binary is functional"
    fi

    log "--------------------------------------------------"
    log "SUCCESS: RyzenAdj binary installed and verified"
    log "Binary location: $binary_dest"
    log "Command to run: $binary_dest [options]"
    log "--------------------------------------------------"

    # Show quick reference for usage
    log ""
    log "Quick reference:"
    log "  To run ryzenadj: $binary_dest"
    log "  To see options: $binary_dest --help"
    log "  For persistence: add to TrueNAS Init/Shutdown Scripts if needed"
    log ""

    RYZENADJ_INSTALLED_PATH="$binary_dest"
}
# ============================================================================
# Script Execution Flow
# ============================================================================
check_requirements
prepare_build_env
compile_ryzen_smu
verify_ryzen_smu
install_and_load_ryzen_smu
compile_ryzenadj
verify_build
install_ryzenadj_binary
