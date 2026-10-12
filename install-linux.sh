#!/usr/bin/env sh
# install-linux.sh — one-command install of ISR on Debian / Ubuntu, including
# a Multipass VM.
#
# One of three platform front doors, named for the platform they are written
# for: install-mac.sh, install-linux.sh, install-windows.ps1.
#
# WHY A SEPARATE SCRIPT AT ALL. install-mac.sh runs correctly on Linux and
# always has — `uname -s` reports Linux, the socket path is real, nothing is
# rewritten. What it cannot do is the part a Mac author has no reason to think
# about, and every one of these has ended an install in the field:
#
#   1. THERE IS NO DOCKER. A Mac running this has Docker Desktop; a fresh
#      Multipass VM has nothing. `die "install Docker Desktop"` is not an
#      instruction anyone can follow inside an Ubuntu guest.
#   2. THE DOCKER GROUP DOES NOT APPLY TO THE SHELL THAT ADDED IT. `usermod -aG
#      docker $USER` takes effect at next login, so the very next command in the
#      same session still fails with a permission error on the socket. This is
#      the single most common Linux-Docker papercut and it looks like a broken
#      installer.
#   3. localhost IS THE WRONG ADDRESS. In a VM the console is on the guest;
#      the person is on the host. Printing http://localhost:9800 sends them to a
#      port on their own laptop, where nothing is listening.
#   4. THE DEFAULT VM IS TOO SMALL. `multipass launch` with no flags gives 1 GB
#      RAM and 5 GB disk. Two ISR images plus the InfluxDB nodes ISR exists to
#      launch do not fit, and the failure arrives late, as a disk-full error
#      during `docker load`, long after the operator stopped watching.
#
# Everything after the preflight is deliberately IDENTICAL to install-mac.sh —
# same ports, same mounts, same env, same state volume, same two-architecture
# staging, same refusal to load an unverified image. `installer_parity_tests` in
# src/cloud_deploy.rs asserts that, because two copies of an install procedure
# drift the moment one is edited alone.
#
#   Usage:
#     ./install-linux.sh
#
#   Auth (pick ONE — tried in this order):
#     • GITHUB_TOKEN=<token> ./install-linux.sh   (optional: rate limit / private REPO)
#     • `gh auth login` first, if the GitHub CLI is installed in this guest
#
#     A fresh Multipass VM has no `gh` and no browser to authorise one in, so
#     GITHUB_TOKEN is the normal path here — the reverse of the Mac.
#
#   Optional overrides (env vars):
#     REPO=M617263Kaplan/influxdb-smart-router   ISR_PORT=9800   ISR_TOOL_PORT=9843   NAME=isr
#     NETWORK=isr-cluster-net   STATE_VOLUME=isr-state
#     ASSUME_YES=1          install missing packages without asking
#     SKIP_DOCKER_INSTALL=1 never touch apt; fail instead if docker is absent
#     STAGE_BOTH_ARCHES=0   skip the spoke-architecture image (saves ~400 MB)
#     FRESH=1               wipe an existing state volume for a clean first run
#
set -eu

# Where release binaries live. Override with REPO=<owner>/<repo> to install
# from a fork or a mirror.
#
# NOT the update feed. ISR self-updates from a separate repo carrying
# SEALED payloads, which this installer has no key to open — pointing
# REPO at it downloads bytes that cannot be unpacked.
REPO="${REPO:-M617263Kaplan/influxdb-smart-router}"
NAME="${NAME:-isr}"
NETWORK="${NETWORK:-isr-cluster-net}"
ISR_PORT="${ISR_PORT:-9800}"
ISR_TOOL_PORT="${ISR_TOOL_PORT:-9843}"
STATE_VOLUME="${STATE_VOLUME:-isr-state}"
# The release API base. Overridable so the installer can be pointed at a
# mirror — and so its refusal to install an unsigned or substituted release
# can be DRIVEN against a hostile one, which is the only way to know the
# check works. Redirecting it is not a way in: the signature is pinned to a
# key this script carries, not to where the bytes came from.
API="${ISR_API:-https://api.github.com/repos/${REPO}}"

# COLOUR ONLY WHERE SOMETHING CAN RENDER IT.
#
# These escapes were unconditional, so any run whose output is CAPTURED rather
# than shown on a terminal printed them as text. Reported 2026-09-29 from a GUI
# dialog on the Mac installer, which had the identical code:
#
#     [1;33m!  [0m A previous ISR state volume ('isr-state') was found — …
#
# The escape lands in FRONT of the message, which is the worst place for it: the
# first thing the reader meets is noise, and the sentence it is standing in
# front of is a warning about losing state.
#
# This matters more here than on the Mac, not less: a Linux install is routinely
# run under cloud-init, Ansible or CI, where output is ALWAYS captured and a
# human reads it later out of a log.
#
# Decided per STREAM, not once for the script. `say` writes to stdout and
# `warn`/`die` to stderr, and a run that redirects one but not the other is
# completely ordinary (`| tee install.log`, `2>errors.txt`).
#
# `%b` rather than embedding the variable in the format string: printf does not
# expand escapes in a `%s` argument, and a variable format string is the other
# way to get this wrong.
if [ -t 1 ]; then _say_on='\033[1;36m'; _say_off='\033[0m'; else _say_on=''; _say_off=''; fi
if [ -t 2 ]; then _err_on='\033[1;33m'; _die_on='\033[1;31m'; _err_off='\033[0m'
             else _err_on='';           _die_on='';           _err_off=''; fi

say()  { printf '%b==>%b %s\n' "$_say_on" "$_say_off" "$1"; }
warn() { printf '%b!  %b %s\n' "$_err_on" "$_err_off" "$1" >&2; }
die()  { printf '%bx  %b %s\n' "$_die_on" "$_err_off" "$1" >&2; exit 1; }

# ─── WIPING THE STATE VOLUME: ASSESS, CLEAR, WIPE ────────────────────────────
#
# Three functions, in that order, and the order is the design. The assessment
# refuses before anything irreversible; the clearing removes only what the
# assessment approved; the wipe still verifies rather than trusting either.
#
# This used to be one line:
#     say "Wiping ..."; $DOCKER volume rm "$STATE_VOLUME" >/dev/null 2>&1 || true
# The claim printed BEFORE the attempt, stderr went to /dev/null, and `|| true`
# swallowed the exit code. Three separate ways for a failure to arrive as
# success, on the one path whose entire purpose is "start from nothing".
#
# MEASURED 2026-09-18: the removal failed with "volume is in use" — containers
# retained from earlier upgrades still referenced the volume even though they
# were stopped — the installer announced a clean first run, and ISR started on a
# 126 MB state.db holding the previous estate: old organizations, adopted
# clusters and approved tool connections, on a screen that says Getting Started.
# The operator hit this twice; the first time cost a day.
#
# WHO HOLDS THE VOLUME, AND IS IT SAFE TO CLEAR THEM? Sets two globals and
# returns non-zero if anything blocks:
#
#   _SVH_REMOVABLE — stopped containers ISR itself labelled, safe to remove: the
#                    only thing they could roll back TO is the state volume this
#                    run destroys on purpose, so keeping them protects nothing.
#   _SVH_BLOCKING  — one line per holder this script will not touch.
#
# THIS RUNS BEFORE ANYTHING IRREVERSIBLE, which is the point. The refusal below
# used to fire AFTER `docker rm -f "$NAME"`, so an operator told "nothing has
# been wiped" had already lost their running ISR and was left with no control
# plane at all. A guard that protects the data after destroying the service is
# only half a guard.
#
# TWO ENUMERATIONS, UNIONED. The comment this replaces called docker's own error
# authoritative and recorded `--filter volume=` finding ONE of five on
# 2026-09-18. Measured again 2026-10-01 against fourteen real holders and every
# source agreed exactly. Both can be true of different docker versions, which is
# an argument for the union rather than for picking a winner — and the Mounts
# scan is the only one complete by construction, since it reads what each
# container actually mounts rather than an index.
assess_state_volume_holders() {
  _SVH_REMOVABLE=''
  _SVH_BLOCKING=''
  # EXIT CODE, NOT EMPTINESS. A host with no containers and a daemon that
  # could not be reached both print nothing, and only one of them means "no
  # holders". Treating the second as clear is how this check would wave
  # through a wipe it never actually looked at — found by a harness where
  # the docker command was unset and the verdict came back "clear to wipe".
  if ! _svh_all="$($DOCKER ps -aq --no-trunc 2>/dev/null)"; then
    echo "" >&2
    echo "REFUSING: could not ask docker which containers exist, so this script" >&2
    echo "  cannot tell whether anything is holding '${STATE_VOLUME}'." >&2
    echo "  NOTHING HAS BEEN REMOVED." >&2
    echo "" >&2
    return 1
  fi
  [ -n "$_svh_all" ] || return 0
  _svh_ids="$(
    {
      $DOCKER ps -aq --no-trunc --filter "volume=${STATE_VOLUME}" 2>/dev/null || true
      # shellcheck disable=SC2086  # deliberate word-splitting over the id list
      $DOCKER inspect $_svh_all \
        --format '{{.Id}} {{range .Mounts}}{{.Name}},{{end}}' 2>/dev/null \
        | awk -v v="$STATE_VOLUME" \
            '{ n = split($2, a, ","); for (i = 1; i <= n; i++) if (a[i] == v) print $1 }'
    } | sed '/^$/d' | sort -u
  )"
  [ -n "$_svh_ids" ] || return 0
  for _svh_id in $_svh_ids; do
    # A container can vanish between the enumeration and this call; an empty row
    # is nothing to act on, not a holder we failed to classify.
    _svh_row="$($DOCKER inspect "$_svh_id" \
      --format '{{.State.Running}}|{{index .Config.Labels "org.opencontainers.image.title"}}|{{.Name}}' \
      2>/dev/null)" || continue
    [ -n "$_svh_row" ] || continue
    _svh_running="${_svh_row%%|*}"
    _svh_rest="${_svh_row#*|}"
    _svh_title="${_svh_rest%%|*}"
    _svh_name="$(printf '%s' "${_svh_rest#*|}" | sed 's|^/||')"
    if [ "$_svh_name" = "$NAME" ]; then
      # The target of this FRESH run. Removed by name a few lines below; it is
      # not a surprise holder.
      continue
    elif [ "$_svh_running" = "true" ]; then
      _SVH_BLOCKING="${_SVH_BLOCKING}    ${_svh_name} — RUNNING
"
    elif [ "$_svh_title" != "ISR" ]; then
      _SVH_BLOCKING="${_SVH_BLOCKING}    ${_svh_name} — stopped, but not an ISR container
"
    else
      _SVH_REMOVABLE="${_SVH_REMOVABLE}${_svh_name} "
    fi
  done
  if [ -n "$_SVH_BLOCKING" ]; then
    echo "" >&2
    echo "REFUSING: something else is holding '${STATE_VOLUME}', so it cannot be wiped." >&2
    echo "  NOTHING HAS BEEN REMOVED — this check runs before anything irreversible." >&2
    echo "" >&2
    printf '%s' "$_SVH_BLOCKING" >&2
    echo "" >&2
    echo "  A RUNNING holder means a second ISR — or something else — is using this state" >&2
    echo "  right now, and stopping it from here would wipe an estate you did not name." >&2
    echo "  A stopped container that is not ISR's is not this script's to delete either." >&2
    echo "" >&2
    echo "  Deal with the containers listed above, then re-run this script." >&2
    echo "" >&2
    return 1
  fi
  return 0
}

# Remove the holders `assess_state_volume_holders` approved, BY NAME, and say
# which. Names rather than ids because the operator has to be able to recognise
# what is going, and because a 64-character id tells them nothing about whether
# they wanted it.
remove_retained_state_volume_holders() {
  [ -n "${_SVH_REMOVABLE:-}" ] || return 0
  say "  removing ISR containers kept from earlier upgrades, which still hold '${STATE_VOLUME}':"
  say "    ${_SVH_REMOVABLE}"
  # shellcheck disable=SC2086  # deliberate word-splitting over the name list
  $DOCKER rm -f $_SVH_REMOVABLE >/dev/null 2>&1 || true
}

# THE WIPE ITSELF, WHICH STILL REFUSES TO CLAIM WHAT IT DID NOT DO.
#
# The pre-flight above should have cleared the way, so reaching the refusal here
# means something changed underneath us — a container started, or docker
# disagreed with both enumerations. It still has to be actionable.
#
# IT NAMES THEM NOW. This used to print docker's raw id list and then
#     docker rm -f <the container ids listed above>
# which is a placeholder the operator had to hand-assemble out of fourteen
# 64-character ids, with no way to tell which were running. Measured 2026-10-01
# on a real refusal: fourteen holders, all stopped, all ISR's own retained
# containers — but docker's list CAN include a running container (reproduced on
# scratch resources), and `rm -f` on one of those stops an ISR nobody asked to
# stop. So the running ones are named and excluded from the command.
wipe_state_volume() {
  _wsv_err="$($DOCKER volume rm "$STATE_VOLUME" 2>&1)" || true
  if $DOCKER volume inspect "$STATE_VOLUME" >/dev/null 2>&1; then
    _wsv_stopped=''
    _wsv_running=''
    for _wsv_id in $(printf '%s\n' "$_wsv_err" \
        | sed -n 's/.*\[\(.*\)\].*/\1/p' | tr ',' '\n' | tr -d ' ' | sed '/^$/d'); do
      _wsv_row="$($DOCKER inspect "$_wsv_id" --format '{{.State.Running}}|{{.Name}}' 2>/dev/null)" || continue
      [ -n "$_wsv_row" ] || continue
      _wsv_n="$(printf '%s' "${_wsv_row#*|}" | sed 's|^/||')"
      if [ "${_wsv_row%%|*}" = "true" ]; then
        _wsv_running="${_wsv_running}    ${_wsv_n} — RUNNING, left alone
"
      else
        _wsv_stopped="${_wsv_stopped}${_wsv_n} "
      fi
    done
    echo "" >&2
    echo "REFUSING: '${STATE_VOLUME}' is still there, so this would NOT be a clean first run." >&2
    echo "  ISR would start on the PREVIOUS estate — old organizations, adopted clusters and" >&2
    echo "  approved tools — while this installer told you it had wiped them." >&2
    echo "" >&2
    if [ -n "$_wsv_running" ] || [ -n "$_wsv_stopped" ]; then
      echo "  Still holding it:" >&2
      [ -z "$_wsv_running" ] || printf '%s' "$_wsv_running" >&2
      [ -z "$_wsv_stopped" ] || echo "    ${_wsv_stopped}" >&2
      echo "" >&2
      if [ -n "$_wsv_stopped" ]; then
        echo "  Remove the stopped ones, then re-run this script:" >&2
        echo "    $DOCKER rm -f ${_wsv_stopped}" >&2
      fi
      if [ -n "$_wsv_running" ]; then
        echo "  A RUNNING holder is not this script's to stop — stop it yourself first." >&2
      fi
    else
      # NOTHING RESOLVED IS NOT THE SAME AS NOTHING HOLDING IT. If the parse
      # found no ids, or every id failed to inspect, say so with docker's own
      # words rather than printing an empty list that reads as "all clear".
      echo "  The holding containers could not be resolved, so here is docker verbatim:" >&2
      echo "    ${_wsv_err}" >&2
    fi
    echo "" >&2
    return 1
  fi
  say "Wiped '${STATE_VOLUME}' — this is a clean first run."
  return 0
}


# ── 0. platform ──────────────────────────────────────────────────────────────
# Point at the right script rather than half-working. Naming the alternative is
# the whole value of splitting these by platform in the first place.
case "$(uname -s 2>/dev/null || echo unknown)" in
  Linux) : ;;
  Darwin) die "This is macOS — use install-mac.sh instead." ;;
  MINGW*|MSYS*|CYGWIN*)
    die "This is a Windows shell — use install-windows.ps1 from PowerShell instead.
     (Git Bash rewrites the Docker socket mount; install-mac.sh documents why.)" ;;
  *) warn "Unrecognised OS '$(uname -s)' — continuing, but this script is written for Debian/Ubuntu." ;;
esac

# Debian family or not. NOT fatal: RHEL/SUSE hosts with docker already installed
# work fine from here, and refusing them would be caution rather than a reason.
# What changes is only whether the apt path below can help.
#
# READ IN A SUBSHELL, NEVER SOURCED INTO THIS ONE. /etc/os-release is a shell
# fragment that assigns NAME, VERSION, ID and more — and `NAME` is this script's
# container name. Sourcing it directly overwrote `NAME=isr` with `NAME=Ubuntu`,
# so a completed install created a container called "Ubuntu", the upgrade-in-
# place check looked for the wrong container on every later run, and the closing
# banner told the operator to type `docker stop Ubuntu`.
#
# Found by running this script inside a real Ubuntu guest, not by reading it.
# Nothing about the source says "this file assigns NAME"; you have to watch it
# happen. The subshell makes the collision impossible rather than remembering
# which variables are taken.
APT=no
if [ -r /etc/os-release ]; then
  OS_PRETTY="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-${ID:-linux}}")"
  OS_FAMILY="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}${ID_LIKE:-}")"
  case "$OS_FAMILY" in
    *debian*|*ubuntu*) APT=yes ;;
  esac
  say "Host: ${OS_PRETTY:-linux}"
fi
[ "$APT" = yes ] || warn "Not a Debian/Ubuntu system — this script will not install packages for you; it expects docker and curl to be present."

# Root vs sudo, resolved once. Multipass's default user has passwordless sudo;
# a container or a hardened host may have neither, and finding that out at the
# first apt call is too late to say anything useful.
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
fi

ask() {  # $1 = question. Yes on ASSUME_YES; yes on a non-tty is NEVER assumed.
  case "${ASSUME_YES:-}" in 1|true|yes|YES) return 0 ;; esac
  [ -t 0 ] || return 1
  printf '    %s [y/N] ' "$1"
  read _a </dev/tty 2>/dev/null || _a=n
  case "$_a" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}

# ── 0b. is this a VM, and is it big enough? ──────────────────────────────────
# Checked BEFORE downloading 150 MB, because the whole point is to fail while
# the fix is still cheap. A Multipass instance cannot be resized while running,
# so learning this at `docker load` costs a full relaunch.
VIRT="none"
command -v systemd-detect-virt >/dev/null 2>&1 && VIRT="$(systemd-detect-virt 2>/dev/null || echo none)"
IN_VM=no
[ "$VIRT" != none ] && [ "$VIRT" != "" ] && IN_VM=yes

# Free space where docker actually stores images, not where we happen to stand.
DOCKER_ROOT=/var/lib/docker
[ -d "$DOCKER_ROOT" ] || DOCKER_ROOT=/var/lib
DISK_FREE_MB="$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
MEM_TOTAL_MB="$(awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)"
# A missing file OR a file without the key both leave this empty, and `[ "" -gt
# 0 ]` is an error, not a false. Defaulted so an unreadable host skips the check
# instead of failing the install over a warning it could not compute.
MEM_TOTAL_MB="${MEM_TOTAL_MB:-0}"

# Thresholds are what ISR ITSELF needs, stated as such. Two loaded images are
# roughly 800 MB; the InfluxDB 3 Enterprise nodes ISR launches are the rest.
UNDERSIZED=no
if [ -n "${DISK_FREE_MB:-}" ] && [ "$DISK_FREE_MB" -lt 8000 ] 2>/dev/null; then
  warn "Only ${DISK_FREE_MB} MB free on ${DOCKER_ROOT}. ISR's own images need ~1 GB; the InfluxDB nodes it launches need several more."
  UNDERSIZED=yes
fi
if [ "$MEM_TOTAL_MB" -gt 0 ] && [ "$MEM_TOTAL_MB" -lt 2000 ] 2>/dev/null; then
  warn "This host has ${MEM_TOTAL_MB} MB RAM. ISR runs, but an InfluxDB 3 node beside it will not."
  UNDERSIZED=yes
fi
if [ "$UNDERSIZED" = yes ] && [ "$IN_VM" = yes ]; then
  warn "This looks like a VM (${VIRT}). If it is Multipass, a VM cannot be resized while running — delete and relaunch from your HOST with:

       multipass delete <name> && multipass purge
       multipass launch --name isr --cpus 2 --memory 4G --disk 20G

     Continuing anyway; the failure, if it comes, will be a disk-full error during 'docker load'."
  ask "Continue with the current size?" || die "Stopped. Relaunch the VM with more room and re-run."
fi

# ── 0c. docker, curl, python3 ────────────────────────────────────────────────
apt_install() {  # $1... = packages
  [ "$APT" = yes ] || die "Missing: $* — and this is not a Debian/Ubuntu host, so install them yourself and re-run."
  [ -n "$SUDO" ] || [ "$(id -u)" -eq 0 ] || die "Missing: $* — and there is no sudo here to install them with. Install them as root and re-run."
  say "Installing: $*"
  $SUDO apt-get update -qq || die "apt-get update failed."
  DEBIAN_FRONTEND=noninteractive $SUDO apt-get install -y -qq "$@" || die "apt-get install $* failed."
}

command -v curl >/dev/null 2>&1 || apt_install curl ca-certificates

if ! command -v docker >/dev/null 2>&1; then
  if [ "${SKIP_DOCKER_INSTALL:-}" = 1 ]; then
    die "Docker is not installed and SKIP_DOCKER_INSTALL=1. Install it and re-run."
  fi
  say "Docker is not installed."
  # docker.io from the distro repo, not the docker-ce repo: it is one package
  # from a source the host already trusts, and it is what a Multipass guest can
  # get without adding a third-party key. Production hosts that want docker-ce
  # should install it first; this script only fills a hole, it does not have an
  # opinion about your package sources.
  if ask "Install it now with apt (package: docker.io)?"; then
    apt_install docker.io
    $SUDO systemctl enable --now docker >/dev/null 2>&1 || true
  else
    die "Docker is required. Install it with:  sudo apt-get install -y docker.io"
  fi
fi

# THE GROUP TRAP. `usermod -aG docker` applies at NEXT LOGIN, so adding the
# group here does not help the shell that is running now. Both halves are done
# and both are stated: sudo carries THIS run, the group carries every run after
# a re-login. Silently using sudo forever would leave a host where the operator
# still cannot type `docker ps`.
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
  if [ -n "$SUDO" ] && $SUDO docker info >/dev/null 2>&1; then
    DOCKER="$SUDO docker"
    if id -nG "$(id -un)" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      warn "You are in the 'docker' group but this shell predates it — using sudo for this run. Log out and back in (or run 'newgrp docker') and plain 'docker' will work."
    else
      say "Adding $(id -un) to the 'docker' group for future sessions."
      $SUDO usermod -aG docker "$(id -un)" 2>/dev/null || warn "Could not add you to the 'docker' group; you will keep needing sudo."
      warn "That takes effect at your NEXT LOGIN. This run uses sudo. Afterwards: log out and back in, or run 'newgrp docker'."
    fi
  else
    die "Docker is installed but not usable — 'docker info' failed and sudo did not help. Is the daemon running?  sudo systemctl start docker"
  fi
fi

# ── 0c. the four ports, checked BEFORE anything is downloaded or offered ──────
#
# This script bound four ports and let `docker run` be the one to find out, so a
# busy port reached the operator as a raw daemon error under `set -e`:
#
#     Bind for 0.0.0.0:8181 failed: port is already allocated
#
# WHY THIS IS CHECKED HERE AND NOT NEXT TO THE `docker run`. The state-volume
# branch further down prints "Re-run with FRESH=1 … to wipe it", and the port
# error lands directly underneath it. An operator reading top to bottom sees a
# failure with, immediately above it, the only remedy this script has offered —
# and takes it. FRESH=1 destroys admins, config, databases, organizations,
# adopted clusters and approved tool connections, and it CANNOT free a port: the
# port is held by a container, and the volume knows nothing about it. Measured
# 2026-09-29 — removing the volume succeeded and the next run failed byte for
# byte the same. The remedy on offer cost everything and changed nothing.
#
# So the fix is not a better error at the `docker run`. It is refusing early
# enough that no destructive advice is ever printed anywhere near a port
# conflict — and before the image download, so the refusal costs seconds rather
# than a few hundred megabytes. It sits after the DOCKER resolution above
# because on this platform `$DOCKER` may be `sudo docker`.
#
# The container this install REPLACES is excluded. An in-place upgrade legitimately
# finds ISR holding all four ports, and a check that did not exclude it would
# refuse every routine upgrade on the machine — a worse failure than the one
# being fixed, and one that would look exactly like a working check.
_port_holder() {  # $1 = port; echoes what publishes it, empty if free
  _ps="$($DOCKER ps --format '{{.Names}} {{.Ports}}' 2>/dev/null)"
  # Containers OTHER than the one this install replaces: a genuine conflict.
  _ph="$(printf '%s\n' "$_ps" \
         | awk -v n="$NAME" -v p=":$1->" '$1 != n && index($0, p) { print $1 }' \
         | tr '\n' ' ')"
  if [ -n "$_ph" ]; then printf 'container %s' "${_ph% }"; return; fi

  # OURS, AND THEREFORE FREE — and the reason this test cannot be skipped.
  #
  # The first version of this check fell straight through to the host probe
  # below, and the positive control caught it on the Mac: a published port is
  # held on the host by Docker's own forwarding process, so the host probe
  # answers "busy" for EVERY container-published port — including the container
  # we are about to replace. All four ports came back held by one pid, and the
  # check refused an ordinary in-place upgrade. Linux publishes through
  # docker-proxy rather than Docker Desktop's vpnkit, which is a different
  # mechanism reaching the same wrong answer, so the guard is needed on both.
  if printf '%s\n' "$_ps" \
     | awk -v n="$NAME" -v p=":$1->" '$1 == n && index($0, p) { f=1 } END { exit !f }'; then
    return
  fi

  # Nothing in Docker publishes it. A non-Docker listener (a distro InfluxDB, an
  # nginx) is just as fatal and names nothing in `docker ps`. `ss` first: it is
  # in iproute2 and present on essentially every modern Linux, where `lsof` is
  # frequently not installed on minimal cloud images. Neither being present must
  # read as "free" — an absent binary reports exactly like an empty port.
  if command -v ss >/dev/null 2>&1; then
    _ph="$(ss -Hltnp "sport = :$1" 2>/dev/null | head -1)"
    if [ -n "$_ph" ]; then printf 'a non-Docker listener'; return 0; fi
  elif command -v lsof >/dev/null 2>&1; then
    _ph="$(lsof -nP -iTCP:"$1" -sTCP:LISTEN -t 2>/dev/null | tr '\n' ' ')"
    if [ -n "$_ph" ]; then printf 'a non-Docker process (pid %s)' "${_ph%% }"; fi
  fi
  # EXPLICIT SUCCESS, AND IT IS LOAD-BEARING UNDER `set -eu`.
  #
  # A function returns its LAST command's status, and `[ -n "$x" ] && printf …`
  # returns 1 when x is empty — which here is the ORDINARY case, a free port.
  # The caller assigns from a command substitution, and an assignment whose
  # substitution failed is exactly the kind of failure `set -e` kills the script
  # for. So "every port is free" — the state of a clean machine, which is this
  # installer's whole audience — aborted the install at exit 1 with NOT ONE LINE
  # of output. Measured 2026-10-01: a 0-byte log and INSTALL_EXIT=1.
  #
  # It never showed up in testing because the machine under test always had an
  # ISR running, which takes the early `return` above. The one input that broke
  # it was the one nobody had.
  return 0
}

_busy=''
for _p in "$ISR_PORT" 8086 8181 "$ISR_TOOL_PORT"; do
  _by="$(_port_holder "$_p")"
  [ -n "$_by" ] && _busy="${_busy}    port ${_p} — held by ${_by}
"
done

if [ -n "$_busy" ]; then
  _self="${0##*/}"
  case "$_self" in sh|bash|dash|zsh|-*|'') _self="the installer" ;; *) _self="sh $_self" ;; esac
  {
    echo ""
    echo "REFUSING: ISR needs four ports and some are already in use."
    echo ""
    printf '%s' "$_busy"
    echo ""
    echo "  Nothing has been downloaded, changed, or removed. Your existing state is"
    echo "  untouched."
    echo ""
    echo "  If those containers are ISR instances you no longer need:"
    echo "      $DOCKER rm -f <name>"
    echo ""
    echo "  If you want this ISR alongside them, move ITS OWN two ports:"
    echo "      ISR_PORT=<free> ISR_TOOL_PORT=<free> ${_self}"
    echo ""
    echo "  Ports 8086 and 8181 are ISR's data plane and cannot be moved here —"
    echo "  whatever holds those has to stop first."
    echo ""
    echo "  Do NOT reach for FRESH=1 to clear this. It wipes admins, config,"
    echo "  databases, organizations, adopted clusters and approved tool connections,"
    echo "  and it cannot free a port — the install then fails in exactly this way"
    echo "  again, with the estate gone."
    echo ""
  } >&2
  exit 1
fi

# JSON parser: prefer python3, fall back to jq. Ubuntu server images ship
# python3; the minimal cloud images sometimes do not.
if command -v python3 >/dev/null 2>&1; then JSON=python3
elif command -v jq >/dev/null 2>&1; then JSON=jq
else
  apt_install python3
  JSON=python3
fi

# ── 1. auth token ────────────────────────────────────────────────────────────
# gh FIRST on the Mac, GITHUB_TOKEN first here: a fresh guest has no gh and no
# browser to complete its device flow in, so the order matches what is actually
# available rather than what the other script does.
TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ] && command -v gh >/dev/null 2>&1; then
  TOKEN="$(gh auth token 2>/dev/null || true)"
fi
# NO TOKEN IS NOT AN ERROR ANY MORE.
#
# This aborted here, BEFORE the first request, so the unauthenticated path was
# never taken: the installer refused on principle rather than trying. The
# default repo is public now, so an anonymous fetch is the normal case and a
# token is only an optional way to raise GitHub's rate limit.
if [ -z "${TOKEN:-}" ]; then
  say "No GitHub token — continuing anonymously (set GITHUB_TOKEN to raise GitHub's rate limit)."
fi

# ── 2. arch ──────────────────────────────────────────────────────────────────
# A Multipass VM inherits the host's architecture: arm64 on Apple silicon,
# amd64 on Intel/AMD. Detected rather than assumed, for exactly that reason.
case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64 ;;
  x86_64|amd64)  ARCH=amd64 ;;
  *) die "Unsupported CPU arch '$(uname -m)'. ISR ships arm64 and amd64 images." ;;
esac
say "Detected ${ARCH} architecture."

# AUTHENTICATED ONLY WHEN THERE IS SOMETHING TO AUTHENTICATE WITH.
#
# This used to send `-H "Authorization: Bearer ${TOKEN}"` unconditionally. With
# no token that is the literal header `Authorization: Bearer `, and GitHub
# answers 401 to a malformed credential rather than treating the request as
# anonymous — so a public user downloading a public asset got an AUTH error and
# went hunting for a token they are not supposed to need. Dropping the header
# entirely is what makes the request anonymous.
auth_curl() {
  if [ -n "${TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer ${TOKEN}" "$@"
  else
    curl -fsSL "$@"
  fi
}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  elif command -v openssl >/dev/null 2>&1; then openssl dgst -sha256 "$1" | awk '{print $NF}'
  else return 1
  fi
}

# ── RELEASE SIGNATURE VERIFICATION ───────────────────────────────────────────
#
# WHY THIS EXISTS. Until now this script compared the image against a SHA256 it
# fetched from the SAME GitHub release as the image. That is integrity against
# CORRUPTION and nothing at all against TAMPERING: whoever can publish the
# payload publishes the manifest beside it, and the manifest was unsigned. It
# then WARNED AND CONTINUED whenever the check could not run — no sha256 tool,
# no entry for this arch, no manifest at all — and a check that continues when
# it cannot run is not a check.
#
# The stakes are not ordinary. This installer mounts the DOCKER SOCKET, so a
# substituted image is root-equivalent on the host that loads it. Once ISR is a
# public download, the easiest path must not also be the unverified one.
#
# THE KEY IS PINNED HERE, never fetched. Fetching it from the release it
# vouches for is the same fallacy as the unsigned manifest. Regenerate with
# `isr signing-pubkey --pem` if the signing key is ever rotated.
RELEASE_SIGNING_PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA5OLkhumKj2HNdvnAgsUA1/Z7TQlmL43K1FjqvcjA3iw=
-----END PUBLIC KEY-----'

# A KNOWN-GOOD SIGNATURE, so "this tool cannot do Ed25519" is never reported as
# "your download was tampered with".
#
# MEASURED 2026-09-10: macOS ships LibreSSL 3.3.6 at /usr/bin/openssl, which
# cannot even LOAD an Ed25519 public key — and it exits 1, exactly as a FORGED
# signature does. Exit status alone cannot tell an old tool from an attack, so
# the verifier proves itself on this vector first. It exercises the whole chain
# the real check uses: the sha256 tool, the message format, the PEM, the verify.
SELFTEST_SIG_B64='acyn8EQz+Z3eFcEa831oqpfU97RgN/aCc8excp2cxGCxH96DayZr9+3pN7LgIs/hWnFEgG12CoOzEGYMjMa1Aw=='

b64_decode() {  # GNU coreutils uses -d, BSD/macOS uses -D
  base64 -d 2>/dev/null || base64 -D 2>/dev/null
}

# The exact bytes `isr sign-manifest` signs. Both sides build this; nothing else
# is signed. The version is INSIDE it, so a genuine signature over an older
# release cannot be replayed for a newer one.
manifest_message() {  # $1 = version (no leading v), $2 = manifest path, $3 = out
  _mm_h="$(sha256_of "$2")" || return 1
  printf 'ISR-RELEASE-MANIFEST-v1\nversion=%s\nsha256=%s\n' "$1" "$_mm_h" > "$3"
}

openssl_verify() {  # $1 = openssl, $2 = pem, $3 = message, $4 = signature
  "$1" pkeyutl -verify -pubin -inkey "$2" -rawin -in "$3" -sigfile "$4" >/dev/null 2>&1
}

verifier_selftest_ok() {  # $1 = candidate openssl
  _st_d="$(mktemp -d)" || return 1
  printf '%s\n' "$RELEASE_SIGNING_PUBKEY_PEM" > "${_st_d}/pub.pem"
  printf 'isr-verifier-selftest\n' > "${_st_d}/m"
  printf '%s' "$SELFTEST_SIG_B64" | b64_decode > "${_st_d}/sig" 2>/dev/null || { rm -rf "$_st_d"; return 1; }
  manifest_message "0.0.0-selftest" "${_st_d}/m" "${_st_d}/msg" || { rm -rf "$_st_d"; return 1; }
  if openssl_verify "$1" "${_st_d}/pub.pem" "${_st_d}/msg" "${_st_d}/sig"; then
    rm -rf "$_st_d"; return 0
  fi
  rm -rf "$_st_d"; return 1
}

# Candidates in order. Homebrew and openssl@3 come BEFORE /usr/bin on purpose:
# on macOS /usr/bin/openssl is the one that cannot do this.
find_verifier() {
  for _fv_c in ${ISR_OPENSSL:-} openssl /opt/homebrew/bin/openssl \
               /usr/local/opt/openssl@3/bin/openssl /opt/homebrew/opt/openssl@3/bin/openssl \
               /usr/local/bin/openssl /usr/bin/openssl; do
    [ -n "$_fv_c" ] || continue
    command -v "$_fv_c" >/dev/null 2>&1 || continue
    if verifier_selftest_ok "$_fv_c"; then printf '%s' "$_fv_c"; return 0; fi
  done
  return 1
}

# SECOND VERIFIER: the ISR that is already running here.
#
# An upgrade on a host with no capable openssl can still be checked, because the
# image already installed is one this host has ALREADY chosen to trust, and it
# carries the same baked public key. Verifying the NEW download with the NEW
# binary would be circular; verifying it with the OLD one is not.
running_isr_image() {
  ${DOCKER:-docker} inspect --format '{{.Config.Image}}' "$NAME" 2>/dev/null | head -1
}
running_isr_version() {
  # WHAT IS RUNNING IS A QUESTION FOR THE BINARY, NOT ITS LABEL.
  #
  # This read the image TAG and pulled the first digits out of it:
  #   isr:v1.2.14-arm64  -> 1.2.14   (fine)
  #   isr:391d24b-arm64  -> 391      (a git revision, parsed as a version)
  #
  # A tag is a label anyone can set; the binary knows its own version. On
  # 2026-09-24 a host running 1.2.14 from a revision-tagged image reported
  # "391", so `sort -V` ranked it above 1.2.15 and the installer REFUSED THE
  # UPGRADE as a downgrade. The guard was right to exist and was fed a number
  # that was never a version.
  #
  # Ask the container first. Fall back to the tag only when it genuinely looks
  # like X.Y.Z — and otherwise answer NOTHING, because an unparseable tag means
  # "I do not know", and guessing is what produced the refusal.
  _rv_img="$(running_isr_image)"
  [ -n "$_rv_img" ] || return 0
  _rv="$(${DOCKER:-docker} exec "$NAME" /usr/local/bin/isr --version 2>/dev/null \
         | sed -n 's/^isr \([0-9][0-9.]*\).*$/\1/p' | head -1)"
  if [ -z "$_rv" ]; then
    # Container not running: ask the image itself.
    _rv="$(${DOCKER:-docker} run --rm --entrypoint /usr/local/bin/isr "$_rv_img" --version 2>/dev/null \
           | sed -n 's/^isr \([0-9][0-9.]*\).*$/\1/p' | head -1)"
  fi
  if [ -z "$_rv" ]; then
    # Last resort: a tag that is unambiguously a version, or nothing at all.
    _rv="$(printf '%s' "$_rv_img" | sed -n 's/^.*isr:v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*$/\1/p')"
  fi
  printf '%s' "$_rv"
}
isr_binary_verify() {  # $1 = manifest, $2 = sig, $3 = version
  _ib_img="$(running_isr_image)"
  [ -n "$_ib_img" ] || return 1
  ${DOCKER:-docker} run --rm -v "${TMP}:/verify:ro" --entrypoint /usr/local/bin/isr "$_ib_img" \
    verify-manifest --manifest "/verify/$(basename "$1")" \
                    --sig "/verify/$(basename "$2")" --version "$3" >/dev/null 2>&1
}

# ── 3. resolve the latest release's image asset for this arch ────────────────
say "Resolving the latest ISR release from ${REPO}…"
REL_JSON="$(auth_curl "${API}/releases/latest")" || die "Could not read ${API}/releases/latest — check that your token has access to ${REPO}."

pick_asset() {  # $1 = filename suffix to match; prints the asset API .url
  if [ "$JSON" = python3 ]; then
    printf '%s' "$REL_JSON" | python3 -c "import sys,json;a=[x for x in json.load(sys.stdin).get('assets',[]) if x['name'].endswith('$1')];print(a[0]['url'] if a else '')"
  else
    printf '%s' "$REL_JSON" | jq -r --arg s "$1" '.assets[]|select(.name|endswith($s))|.url' | head -1
  fi
}
TAG="$(printf '%s' "$REL_JSON" | { [ "$JSON" = python3 ] && python3 -c 'import sys,json;print(json.load(sys.stdin).get("tag_name",""))' || jq -r .tag_name; })"
IMG_URL="$(pick_asset "linux-${ARCH}-image.tar.gz")"
[ -n "$IMG_URL" ] || die "The latest release (${TAG:-?}) has no linux-${ARCH} image asset."
say "Latest release: ${TAG}."

# REFUSE A DOWNGRADE — a signature proves PROVENANCE, never FRESHNESS.
#
# An attacker who can choose which release you resolve serves an OLDER,
# GENUINELY SIGNED one with a known bug, and every check above passes. The
# console's one-click path already refuses this (`selfupgrade::version_cmp`);
# the script is the path that actually gets scripted.
#
# `sort -V`, never a string compare: v1.2.10 must beat v1.2.9, and on this line
# every comparison in the estate had to be re-driven when the first two-digit
# patch shipped.
CURRENT_VER="$(running_isr_version)"
if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" != "${TAG#v}" ]; then
  if [ "$(printf '%s\n%s\n' "$CURRENT_VER" "${TAG#v}" | sort -V | head -1)" = "${TAG#v}" ]; then
    if [ "${ISR_ALLOW_DOWNGRADE:-0}" = "1" ]; then
      warn "DOWNGRADING ${CURRENT_VER} -> ${TAG#v} because ISR_ALLOW_DOWNGRADE=1. State written by the newer build may not be readable by the older one."
    else
      die "REFUSING TO DOWNGRADE: this host runs ${CURRENT_VER} and ${REPO} resolved ${TAG}.

  A release being older than what you already run is how a signed-but-stale
  build gets re-served with a bug you have already moved past — the signature
  would be perfectly valid.

  If this is deliberate (a rollback you intend), re-run with
  ISR_ALLOW_DOWNGRADE=1. Nothing has been installed."
    fi
  fi
fi

# ── 4. download (+ verify checksum when available) ───────────────────────────
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TARBALL="${TMP}/isr-${ARCH}-image.tar.gz"
say "Downloading the ${ARCH} image tarball…"
auth_curl -H "Accept: application/octet-stream" -o "$TARBALL" "$IMG_URL" || die "Download failed."

# THE ONE DOCUMENTED ESCAPE, and it covers exactly one case: this host CANNOT
# verify. It never covers a signature that verified and was WRONG — that is an
# attack or a corrupt publish, and there is no legitimate reason to continue
# through it.
refuse_unverified() {  # $1 = what is wrong, $2 = how to fix it
  if [ "${ISR_ALLOW_UNVERIFIED:-0}" = "1" ]; then
    warn "=============================================================="
    warn "INSTALLING AN UNVERIFIED IMAGE — ISR_ALLOW_UNVERIFIED=1 is set."
    warn "$1"
    warn "This image could have been substituted in transit, and this"
    warn "installer mounts the Docker socket, so it would run as root here."
    warn "=============================================================="
    return 0
  fi
  die "REFUSING TO INSTALL — the release could not be verified.
  $1
  $2
  If you accept the risk, re-run with ISR_ALLOW_UNVERIFIED=1."
}

VERSION="${TAG#v}"
MANIFEST_TRUSTED=0
SUMS_URL="$(pick_asset "SHA256SUMS.txt")"
SIG_URL="$(pick_asset "SHA256SUMS.txt.sig")"

if [ -z "$SUMS_URL" ] || [ -z "$SIG_URL" ]; then
  refuse_unverified \
    "Release ${TAG} publishes no signed manifest (needs both SHA256SUMS.txt and SHA256SUMS.txt.sig)." \
    "Releases are signed from v1.2.13 onward; an earlier release cannot be verified by this installer."
else
  auth_curl -H "Accept: application/octet-stream" -o "${TMP}/SHA256SUMS.txt" "$SUMS_URL" \
    || die "Could not download SHA256SUMS.txt from release ${TAG}."
  auth_curl -H "Accept: application/octet-stream" -o "${TMP}/SHA256SUMS.txt.sig" "$SIG_URL" \
    || die "Could not download SHA256SUMS.txt.sig from release ${TAG}."
  printf '%s\n' "$RELEASE_SIGNING_PUBKEY_PEM" > "${TMP}/pub.pem"

  VERIFIER="$(find_verifier || true)"
  if [ -n "$VERIFIER" ]; then
    manifest_message "$VERSION" "${TMP}/SHA256SUMS.txt" "${TMP}/manifest.msg" \
      || die "No sha256 tool on this host (looked for sha256sum, shasum, openssl), so the release cannot be verified."
    if openssl_verify "$VERIFIER" "${TMP}/pub.pem" "${TMP}/manifest.msg" "${TMP}/SHA256SUMS.txt.sig"; then
      say "Release signature verified for ${TAG} (${VERIFIER})."
      MANIFEST_TRUSTED=1
    else
      # NOT overridable, and said plainly. The verifier proved itself on a known
      # vector before this ran, so this is not "your openssl is old" — the
      # signature genuinely does not match this manifest at this version.
      die "SIGNATURE INVALID for release ${TAG}.

  The manifest downloaded from ${REPO} is NOT the one InfluxData signed for
  version ${VERSION}. Either it was modified in transit, or it belongs to a
  different release being served in place of this one.

  Nothing has been installed. Do not re-run with ISR_ALLOW_UNVERIFIED=1 to get
  past this — that flag is for a host that cannot verify, not for a release that
  failed to."
    fi
  elif isr_binary_verify "${TMP}/SHA256SUMS.txt" "${TMP}/SHA256SUMS.txt.sig" "$VERSION"; then
    say "Release signature verified for ${TAG} by the ISR already installed here."
    MANIFEST_TRUSTED=1
  else
    refuse_unverified \
      "No tool on this host can verify an Ed25519 signature (tried openssl on the usual paths; each was checked against a known-good signature first)." \
      "Install OpenSSL 3 and re-run — 'apt-get install -y openssl', 'dnf install -y openssl', or on macOS 'brew install openssl@3'. Point ISR_OPENSSL=/path/to/openssl at it if it is somewhere unusual."
  fi
fi

# The image hash, checked against a manifest that is now TRUSTED rather than
# merely downloaded. Missing is a refusal, not a warning: a signed manifest with
# no entry for this architecture means the release is incomplete, and loading
# the tarball anyway is loading something nothing vouches for.
if [ "$MANIFEST_TRUSTED" = "1" ]; then
  WANT="$(grep "linux-${ARCH}-image.tar.gz" "${TMP}/SHA256SUMS.txt" 2>/dev/null | awk '{print $1}' | head -1)"
  [ -n "$WANT" ] || die "The signed manifest for ${TAG} has no entry for linux-${ARCH}-image.tar.gz — the release is incomplete. Nothing has been installed."
  GOT="$(sha256_of "$TARBALL")" || die "No sha256 tool on this host, so the downloaded image cannot be checked against the signed manifest."
  [ "$WANT" = "$GOT" ] || die "Image checksum MISMATCH against the SIGNED manifest for ${TAG}.
  expected ${WANT}
  got      ${GOT}
  The manifest is authentic, so the IMAGE is the thing that is wrong. Nothing has been installed."
  say "Image checksum verified against the signed manifest."
elif [ -s "${TMP}/SHA256SUMS.txt" ]; then
  # Override path only. Still worth comparing, but say exactly what it proves:
  # both halves came from the same place, so this detects a damaged download and
  # no attack at all.
  WANT="$(grep "linux-${ARCH}-image.tar.gz" "${TMP}/SHA256SUMS.txt" 2>/dev/null | awk '{print $1}' | head -1)"
  if [ -n "$WANT" ] && GOT="$(sha256_of "$TARBALL")"; then
    [ "$WANT" = "$GOT" ] || die "Checksum MISMATCH — refusing to load a corrupt/tampered image."
    warn "Checksum matches an UNVERIFIED manifest: this detects a damaged download, not a substituted one."
  fi
fi

# ── 5. load into Docker ──────────────────────────────────────────────────────
say "Loading the image into Docker…"
LOADED="$($DOCKER load -i "$TARBALL")"
IMAGE="$(printf '%s' "$LOADED" | grep -oE 'isr:[^ ]+' | head -1)"
[ -n "$IMAGE" ] || die "Could not determine the loaded image tag from: ${LOADED}"
say "Loaded ${IMAGE}."

# ── 5b. stage the OTHER architecture, for spokes ─────────────────────────────
# Same reason as install-mac.sh: a hub deploys a spoke by staging an image for
# the SPOKE's architecture, and an arm64 hub deploying an x86_64 spoke needs the
# amd64 image it never downloaded for itself.
#
# ONE DIFFERENCE FROM THE MAC, and it is the disk. A 5 GB Multipass VM can hold
# ISR's own image and not the second one, and a failed `docker load` there can
# leave the filesystem full enough to break the container that already works.
# So on a small disk this is SKIPPED and SAID, rather than attempted and hoped.
case "$ARCH" in
  arm64) OTHER=amd64 ;;
  amd64) OTHER=arm64 ;;
  *)     OTHER="" ;;
esac
STAGE_BOTH="${STAGE_BOTH_ARCHES:-1}"
DISK_NOW_MB="$(df -Pm "$DOCKER_ROOT" 2>/dev/null | awk 'NR==2{print $4}')"
if [ -n "$OTHER" ] && [ "$STAGE_BOTH" != 0 ] && [ -n "${DISK_NOW_MB:-}" ] && [ "$DISK_NOW_MB" -lt 2000 ] 2>/dev/null; then
  warn "Skipping the ${OTHER} spoke image: only ${DISK_NOW_MB} MB free, and loading it could fill the disk under the running hub. Deploying an ${OTHER} spoke later will tell you how to add it."
  STAGE_BOTH=0
fi
if [ -n "$OTHER" ] && [ "$STAGE_BOTH" != 0 ]; then
  OTHER_URL="$(pick_asset "linux-${OTHER}-image.tar.gz")"
  if [ -n "$OTHER_URL" ]; then
    say "Also staging the ${OTHER} image, so this hub can deploy ${OTHER} spokes…"
    OTHER_TARBALL="${TMP}/isr-${OTHER}-image.tar.gz"
    if auth_curl -H "Accept: application/octet-stream" -o "$OTHER_TARBALL" "$OTHER_URL"; then
      OTHER_WANT="$(grep "linux-${OTHER}-image.tar.gz" "${TMP}/SHA256SUMS.txt" 2>/dev/null | awk '{print $1}' | head -1)"
      OTHER_OK=1
      if [ -n "$OTHER_WANT" ]; then
        if OTHER_GOT="$(sha256_of "$OTHER_TARBALL")"; then
          [ "$OTHER_WANT" = "$OTHER_GOT" ] || { say "  ${OTHER} image checksum MISMATCH — skipping it."; OTHER_OK=0; }
        else
          say "  ${OTHER} image NOT VERIFIED (no sha256 tool) — skipping it rather than loading it unverified."
          OTHER_OK=0
        fi
      fi
      if [ "$OTHER_OK" = 1 ]; then
        OTHER_LOADED="$($DOCKER load -i "$OTHER_TARBALL" 2>&1)" \
          && say "  Staged $(printf '%s' "$OTHER_LOADED" | grep -oE 'isr:[^ ]+' | head -1) for ${OTHER} spokes." \
          || say "  Could not load the ${OTHER} image — spoke deploys to ${OTHER} hosts will explain how to add it."
      fi
    else
      say "  Could not download the ${OTHER} image — continuing; the hub itself is unaffected."
    fi
  fi
fi

# ── 6. run the hub ───────────────────────────────────────────────────────────
$DOCKER network create "$NETWORK" >/dev/null 2>&1 || true

# State volume handling, identical in behaviour to install-mac.sh: an existing
# volume outlives `docker rm`, so a "fresh" install silently lands on a login
# screen instead of Getting Started unless the choice is made explicitly.
FRESH="${FRESH:-}"
first_run=yes
had_container=no; $DOCKER ps -a --format '{{.Names}}' | grep -qx "$NAME" && had_container=yes
has_state=no;     $DOCKER volume inspect "$STATE_VOLUME" >/dev/null 2>&1 && has_state=yes
KEEP_ENV_FILE=""

# CAPTURE THE OLD CONTAINER'S ISR_* ENVIRONMENT, CALLABLE FROM EVERY BRANCH.
#
# This logic lived inside the in-place-upgrade branch alone, so `FRESH=1` — which
# takes the branch ABOVE it — dropped every variable the operator had set. That
# branch already carries the reason it matters: a reinstall once rolled a
# deployment back to a template predating the tool port and ISR_AGENT_IMAGE, and
# "the connected Traffic Lab lost its channel and its agent image in one stroke,
# and the failure surfaced in the TOOL's UI, not here."
#
# THAT REASONING IS NOT ABOUT UPGRADES. It is about this script's template being
# NARROWER THAN A REAL DEPLOYMENT, and FRESH does not change that. FRESH wipes
# STATE and the ESTATE; how the container is INVOKED is neither. Nothing here
# asks for it, so nothing here can restore it — dropping it silently sends
# somebody to a 409 on a clean first run with no clue where it went.
#
# Must be called BEFORE the container is removed. The variables this template
# sets itself are excluded; everything else rides along.
capture_isr_env() {  # $1 = what to call it when reporting
  [ "$had_container" = yes ] || return 0
  KEEP_ENV_FILE="$(mktemp)"
  $DOCKER inspect "$NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | grep '^ISR_' \
    | grep -vE '^ISR_(LISTEN|DATA_LISTEN|STATE_DB|WRITE_QUEUE_PATH|ENCRYPTION_KEY_FILE)=' \
    > "$KEEP_ENV_FILE" || true
  if [ -s "$KEEP_ENV_FILE" ]; then
    say "  $1: $(cut -d= -f1 "$KEEP_ENV_FILE" | tr '\n' ' ')"
  else
    rm -f "$KEEP_ENV_FILE"; KEEP_ENV_FILE=""
  fi
}

if [ "$FRESH" = 1 ] || [ "$FRESH" = true ]; then
  # FRESH MEANS THE ESTATE, NOT JUST ISR'S MEMORY OF IT.
  #
  # This removed the ISR container and its state volume and stopped there — so a
  # "clean first run" came up next to the PREVIOUS run's InfluxDB nodes, still
  # running, and its object store, still full. Two consequences, both measured
  # on the operator's machine 2026-09-11:
  #
  #   1. The bucket still held `commercial_license` from an earlier cluster. A
  #      node launched with INFLUXDB3_LICENSE_TYPE=trial reads its object store
  #      on boot, finds that licence and reports LICENSED — so every "trial"
  #      after the first silently came up commercially licensed and no trial was
  #      ever requested.
  #   2. Containers ISR launched kept running with nobody managing them. The
  #      console has a whole "stranded containers" surface for this exact
  #      aftermath: "four InfluxDB nodes ran for sixteen hours after the ISR that
  #      launched them was replaced".
  #
  # Everything ISR launches carries `isr.cloud=managed`, so what ISR owns is
  # knowable and is what gets removed. Anything unlabelled is someone else's and
  # is never touched.
  # ── REFUSE WHEN A SECOND ISR IS RUNNING ON THIS HOST ─────────────────────
  #
  # THE SWEEP BELOW CANNOT TELL WHOSE CONTAINERS ARE WHOSE. It selects
  # `label=isr.cloud=managed` with no per-instance qualifier, so it removes
  # every container ANY ISR on this host has ever launched — nodes, MinIO, the
  # decoy, Grafana — and the volumes after it, including `isr-lic-<cluster>`
  # holding a commercial licence.
  #
  # The comment above says "what ISR owns is knowable and is what gets removed".
  # That is true for ONE ISR and false for two: the label means "managed by AN
  # ISR" and the code reads it as "managed by THIS ISR". The singular was the
  # unstated assumption, which is why it survived being written down.
  #
  # Measured 12 Sep 2026: two control planes running side by side — a demo
  # rehearsal instance and the operator's own — where either running FRESH would
  # have silently destroyed the other's estate. The victim gets no error; the
  # containers simply stop existing.
  #
  # This is a PROXY, and an honest one: a second running ISR does not prove it
  # owns any of the labelled containers, and its absence does not prove it does
  # not. The real fix is ownership on the label at launch
  # (`isr.cloud.instance=<name>`), which only helps containers started after it
  # ships. This refusal helps the machine you are standing at now.
  OTHER_ISR="$($DOCKER ps --filter "label=org.opencontainers.image.title=ISR" \
      --format '{{.Names}}' 2>/dev/null | grep -v "^${NAME}$" | tr '\n' ' ' || true)"
  if [ -n "${OTHER_ISR# }" ] && [ "${ISR_FRESH_ACROSS_INSTANCES:-0}" != "1" ]; then
    echo "" >&2
    echo "REFUSING FRESH=1: another ISR is running on this host — ${OTHER_ISR}" >&2
    echo "" >&2
    echo "  FRESH removes every container labelled isr.cloud=managed, and that label does" >&2
    echo "  not say WHICH ISR launched it. Wiping from here would take that instance's" >&2
    echo "  nodes, object store and licence volumes with it, silently and with no error" >&2
    echo "  on their side." >&2
    echo "" >&2
    echo "  Stop the other instance first, or remove this one by name:" >&2
    echo "    $DOCKER rm -f ${NAME} && $DOCKER volume rm ${STATE_VOLUME}" >&2
    echo "" >&2
    echo "  If you own BOTH and mean to wipe both estates, say so:" >&2
    echo "    ISR_FRESH_ACROSS_INSTANCES=1 FRESH=1 …" >&2
    exit 1
  fi
  if [ -n "${OTHER_ISR# }" ]; then
    warn "ISR_FRESH_ACROSS_INSTANCES=1 — wiping the estate of ${OTHER_ISR} as well as this one."
  fi

  say "FRESH=1 — wiping this ISR and everything it launched, for a genuinely clean first run."
  capture_isr_env "Keeping how the container is RUN (state and estate still go)"
  # BEFORE ANYTHING IRREVERSIBLE. `wipe_state_volume` can refuse, and it used to
  # refuse one line AFTER removing "$NAME" — so an operator reading "this would
  # NOT be a clean first run, nothing was wiped" had already lost their running
  # ISR, and was left with no control plane and a script that exited 1.
  assess_state_volume_holders || exit 1
  $DOCKER rm -f "$NAME" >/dev/null 2>&1 || true
  remove_retained_state_volume_holders
  wipe_state_volume || exit 1
  # The nodes, MinIO, the decoy, Grafana — every container ISR labelled as its own.
  FRESH_MANAGED="$($DOCKER ps -aq --filter "label=isr.cloud=managed" 2>/dev/null || true)"
  if [ -n "$FRESH_MANAGED" ]; then
    FRESH_NAMES="$($DOCKER inspect --format '{{.Name}}' $FRESH_MANAGED 2>/dev/null | tr -d '/' | tr '\n' ' ')"
    say "  removing containers ISR launched: ${FRESH_NAMES}"
    # shellcheck disable=SC2086  # deliberate word-splitting over the id list
    $DOCKER rm -f $FRESH_MANAGED >/dev/null 2>&1 || true
  fi
  # AND THE OBJECT STORE, which is the one that silently survives a reinstall and
  # re-licenses the next cluster. Named volumes ISR provisions for MinIO.
  # EVERY VOLUME ISR PROVISIONS FOR THE ESTATE, not just the object store.
  # `isr-lic-<cluster>` holds a commercial licence JWT that nodes mount with
  # --license-file, which takes PRECEDENCE over the object store — so it is the
  # more direct of the two carry-over paths, and it survived a reinstall exactly
  # the same way. Measured on the operator's machine: isr-lic-awesome still held
  # a 562-byte commercial_license after the cluster was gone.
  FRESH_VOLS="$($DOCKER volume ls -q 2>/dev/null | grep -E '^isr-(minio|data|lic-|admin-token|grafana-prov)' || true)"
  if [ -n "$FRESH_VOLS" ]; then
    say "  removing object-store volumes: $(printf '%s ' $FRESH_VOLS)"
    # shellcheck disable=SC2086
    $DOCKER volume rm $FRESH_VOLS >/dev/null 2>&1 || true
  fi
elif [ "$had_container" = yes ]; then
  warn "Existing '${NAME}' container found — upgrading in place (admins/config in '${STATE_VOLUME}' are kept)."
  # Carry the old container's ISR_* environment forward. A reinstall that
  # replayed this script's fixed template would silently drop every variable an
  # operator had added — observed live on 2026-08-16, and it cost a connected
  # Traffic Lab its channel and its agent image in one stroke.
  capture_isr_env "Carrying forward from the old container"
  $DOCKER rm -f "$NAME" >/dev/null 2>&1 || true
  first_run=no
elif [ "$has_state" = yes ]; then
  warn "A previous ISR state volume ('${STATE_VOLUME}') was found — it still holds the admins and config from an earlier install, so ISR will start at the LOGIN screen, not Getting Started."
  if [ -t 0 ]; then
    printf '    Start [f]resh (wipe it and run Getting Started) or [k]eep it (sign in with the old credentials)? [k/f] '
    read ans </dev/tty 2>/dev/null || ans=k
    case "$ans" in
      # SAME THREE STEPS AS THE FRESH PATH. This branch is reached when the
      # state volume exists and the container does NOT — which is exactly where
      # an operator lands after a FRESH run refused — so the retained containers
      # holding the volume are still there and the bare wipe would refuse again.
      f|F) assess_state_volume_holders || exit 1
           remove_retained_state_volume_holders
           wipe_state_volume || exit 1 ;;
      *)   say "Keeping existing state — sign in with your previous credentials (Danger Zone → Factory reset wipes it later)."; first_run=no ;;
    esac
  else
    warn "Non-interactive shell — keeping existing state. Re-run with  FRESH=1 sh install-linux.sh  to wipe it and get Getting Started."
    first_run=no
  fi
fi

DOCKER_SOCK="/var/run/docker.sock"

# ISR-006: encryption at rest, generated here because ISR cannot do it itself —
# a key stored inside the database it encrypts is a ritual, not a control. On
# the host, mounted read-only, and generated for a FIRST RUN only: retrofitting
# an existing install would be a data-loss risk with a key nobody knows exists.
#
# $HOME IS NOT ROOT'S HOME just because docker needs sudo. The key belongs to
# the person who installed ISR, so it is written under their home even when the
# daemon is reached with sudo — otherwise a `sudo sh install-linux.sh` and a
# plain one would put it in two different places and the second run would
# generate a second key for the same database.
KEY_DIR="${ISR_KEY_DIR:-${HOME}/.isr}"
KEY_FILE="${KEY_DIR}/encryption.key"
KEY_MOUNT=""
if [ "$first_run" = yes ] || [ -f "$KEY_FILE" ]; then
  if [ ! -f "$KEY_FILE" ]; then
    mkdir -p "$KEY_DIR" 2>/dev/null || true
    chmod 700 "$KEY_DIR" 2>/dev/null || true
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -base64 32 > "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
    fi
    if [ ! -s "$KEY_FILE" ]; then
      head -c 32 /dev/urandom | base64 | tr -d '\n' > "$KEY_FILE" 2>/dev/null || rm -f "$KEY_FILE"
    fi
    if [ -s "$KEY_FILE" ]; then
      chmod 400 "$KEY_FILE" 2>/dev/null || true
      say "Generated an encryption-at-rest key: ${KEY_FILE}"
      warn "BACK THIS FILE UP, and off this VM. Without it the credentials in ISR's state database cannot be read — not by you either. A 'multipass delete' takes the key with it."
    else
      warn "Could not generate an encryption key; ISR will start with encryption at rest OFF."
    fi
  fi
  if [ -s "$KEY_FILE" ]; then
    KEY_MOUNT="$KEY_FILE"
  fi
else
  warn "This install already has state, so encryption at rest is left as it was. Existing credentials stay readable in the '${STATE_VOLUME}' volume; see the docs to enable encryption and re-save them."
fi

say "Starting ISR…"
# shellcheck disable=SC2086
$DOCKER run -d --name "$NAME" --network "$NETWORK" --restart unless-stopped \
  -p "${ISR_PORT}:9800" -p 8086:8086 -p 8181:8181 -p "${ISR_TOOL_PORT}:9843" \
  -v "${DOCKER_SOCK}:/var/run/docker.sock" \
  -v "$STATE_VOLUME":/var/lib/isr \
  ${KEY_MOUNT:+-v "${KEY_MOUNT}:/etc/isr/encryption.key:ro"} \
  ${KEY_MOUNT:+-e ISR_ENCRYPTION_KEY_FILE=/etc/isr/encryption.key} \
  ${KEEP_ENV_FILE:+--env-file "$KEEP_ENV_FILE"} \
  -e ISR_LISTEN=0.0.0.0:9800 \
  -e ISR_DATA_LISTEN=0.0.0.0:8086,0.0.0.0:8181 \
  -e ISR_STATE_DB=/var/lib/isr/state.db \
  -e ISR_WRITE_QUEUE_PATH=/var/lib/isr/write-queue.jsonl \
  "$IMAGE" --config /etc/isr/config.yaml >/dev/null
$DOCKER network connect bridge "$NAME" >/dev/null 2>&1 || true
if [ -n "$KEEP_ENV_FILE" ]; then rm -f "$KEEP_ENV_FILE"; fi

# Wait for the console to answer, and REMEMBER whether it did — probed on
# loopback, which is correct FROM HERE regardless of how it is reached from
# outside.
URL="http://localhost:${ISR_PORT}"
ready=no
i=0; while [ "$i" -lt 30 ]; do
  if curl -fsS "${URL}/api/isr/overview" >/dev/null 2>&1; then ready=yes; break; fi
  i=$((i+1)); sleep 1
done

# ── 7. the address that actually works from where the person is sitting ──────
#
# THE REASON THIS SCRIPT EXISTS, in one block. On a Mac, localhost is right. In
# a VM it is right only for the shell that just ran the install, and wrong for
# the browser the operator will use. So the guest's routable address is found
# and printed FIRST, and localhost is offered second and labelled.
#
# ASK THE ROUTING TABLE, don't filter a list of addresses. The default route's
# source address is by definition the one this host is reachable on, and it is
# never the docker bridge — which `hostname -I` also lists, and which is
# routable from a Linux host and NOT from a Multipass host. Printing a 172.17.x
# there would be an address that works on the author's machine and not the
# reader's.
#
# The fallback exists for hosts without iproute2, and there the docker ranges
# have to be excluded by hand. That filter is deliberately narrow: 172.16/12 is
# a legitimate private range someone's real network may use, so only the
# 172.17–172.31 that docker actually allocates from is dropped.
GUEST_IP=""
if command -v ip >/dev/null 2>&1; then
  GUEST_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.*[[:space:]]src[[:space:]]\([0-9.]*\).*/\1/p' | head -1)"
fi
if [ -z "$GUEST_IP" ] && command -v hostname >/dev/null 2>&1; then
  GUEST_IP="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^172\.1[7-9]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[01]\.' | grep -vx '' | head -1)"
fi

if [ -n "$GUEST_IP" ] && [ "$IN_VM" = yes ]; then
  ACCESS="  Open the console:   http://${GUEST_IP}:${ISR_PORT}      <- from your HOST's browser
  From inside this guest: ${URL}
                      (this is a ${VIRT} guest; 'localhost' means the guest, not your laptop)"
elif [ -n "$GUEST_IP" ]; then
  ACCESS="  Open the console:   ${URL}
  From another machine:   http://${GUEST_IP}:${ISR_PORT}"
else
  ACCESS="  Open the console:   ${URL}"
fi

# ufw is inactive on a stock Multipass image, so this is usually silent — but a
# hardened host that drops 9800 produces a hang with no explanation anywhere.
if command -v ufw >/dev/null 2>&1 && $SUDO ufw status 2>/dev/null | grep -qi '^Status: active'; then
  warn "ufw is active. If the console does not answer from outside this host:  sudo ufw allow ${ISR_PORT}/tcp && sudo ufw allow ${ISR_TOOL_PORT}/tcp"
fi

if [ "$first_run" = yes ]; then
  SIGNIN="First-run sign-in:  admin / admin  (you'll create your own admin next)
  Then follow Getting Started to stand up a live InfluxDB 3 cluster."
else
  SIGNIN="Sign-in:            use your EXISTING credentials from the prior install (this reused the '${STATE_VOLUME}' state volume).
  To start clean at Getting Started instead:  FRESH=1 sh install-linux.sh"
fi

if [ "$ready" = yes ]; then
  STATUS="✅ ISR ${TAG} is running."
else
  # Say what is actually known: the container was started and the console did
  # not answer within the window. Claiming success here is the defect that made
  # a stale record look like a healthy one everywhere else in this codebase.
  STATUS="⚠️  ISR ${TAG} was started, but its console did not answer within 30s.
     Nothing was rolled back — it may still be coming up. Check:  docker logs -f ${NAME}"
fi

cat <<EOF

  ${STATUS}

${ACCESS}
  ${SIGNIN}

  Stop:   docker stop ${NAME}
  Start:  docker start ${NAME}
  Logs:   docker logs -f ${NAME}
EOF
