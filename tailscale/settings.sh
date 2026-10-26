#!/system/bin/sh
set -e

# Custom settings

# Set Magisk Tailscale module variables
TS_MOD_DIR="/data/adb/modules/magisk-tailscaled" # Bad code, if magisk in the future change the path location, need to change this.
export TS_MOD_PROP="${TS_MOD_DIR}/module.prop"

# Set tailscale directory variables
TS_DIR="/data/adb/tailscale"

# Set path environment for busybox & other.
export PATH="${TS_DIR}/bin:${TS_DIR}/scripts:/data/adb/magisk:/data/adb/ksu/bin:$PATH:/system/bin:${TS_MOD_DIR}/system/bin"
export HOME="/data/adb/tailscale/" # Because tailscaled will write log to $HOME

# Set tailscaled directory variables
export TS_RUN_DIR="${TS_DIR}/run"
mkdir -p "$TS_RUN_DIR" 2>/dev/null || true

# Set tailscaled & tailscale configuration
# Official-source binaries have NO Android default paths (upstream
# anasfanani fork baked --statedir/--socket into its binary; ours does not),
# so they are passed explicitly:
#   tun        - real kernel TUN ("tailscale0"). The module ships GOOS=linux
#                static builds on purpose: GOOS=android builds hard-exclude
#                the Linux router ("creating router: unsupported OS android").
#                TUN mode is mandatory — no userspace fallback.
#   statedir   - state file lives beside module data (survives updates)
#   socket     - module run dir (CLI wrapper uses the same path)
export TS_SOCKET="${TS_RUN_DIR}/tailscaled.sock"
# shellcheck disable=SC2153
export TS_DAEMON_CMD="tailscaled --tun=tailscale0 --statedir=${TS_DIR} --socket=${TS_SOCKET} --port=41641 -no-logs-no-support"

# Set tailscaled log variables
export TS_LOG_FILE="${TS_RUN_DIR}/tailscaled.log"
export TS_RUN_LOG_FILE="${TS_RUN_DIR}/runs.log"

# Take the current time
CURRENT_TIME=$(date +"%I:%M %P")

# Coloring
normal="\033[0m"
orange="\033[1;38;5;208m"
red="\033[1;31m"
green="\033[1;32m"
yellow="\033[1;33m"
blue="\033[1;34m"

# Logs function
log() {
  # Selects the text color according to the parameters
  case $1 in
  Info) color="${blue}" ;;
  Success) color="${green}" ;;
  Error) color="${red}" ;;
  Warning) color="${yellow}" ;;
  Debug) color="${orange}" ;;
  *) color="${normal}" ;;
  esac
  # Add messages to time and parameters
  message="${CURRENT_TIME} [$1]: $2"
  if [ -z "$color" ]; then
    echo "${CURRENT_TIME} [Debug]: $1 $2" >>${TS_RUN_LOG_FILE} 2>&1
    return
  fi
  if [ -t 1 ]; then
    # Prints messages to the console
    echo "${color}${message}${normal}"
    echo "${message}" >>${TS_RUN_LOG_FILE} 2>&1
  else
    # Print messages to a log file
    echo "${message}" >>${TS_RUN_LOG_FILE} 2>&1
  fi
}

[ -n "${DEBUG:-}" ] && set -u && set -x && PS4='+ ${0##*/}:${LINENO}: ' || true