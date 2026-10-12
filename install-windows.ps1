# install-windows.ps1 — one-command install of ISR on Windows 11 (Docker Desktop).
#
# One of three platform front doors, named for the platform they are written
# for: install-mac.sh, install-linux.sh, install-windows.ps1.
#
# PowerShell DELIBERATELY, not a convenience copy: install-mac.sh's own comments
# record that Git Bash rewrites the docker-socket mount (`/var/run/docker.sock`
# becomes `C:/Program Files/Git/var/run/docker.sock`) and call it "the known
# failure". PowerShell performs no such rewriting, so on Windows this script is
# the correct front door.
#
# What it does: resolves the M617263Kaplan/influxdb-smart-router release, downloads
# the amd64 image tarball, `docker load`s it, creates the NAMED state volume
# (never a C:\ bind mount — a state DB on the 9p/virtiofs translation layer is
# the field failure that motivated docs/install-windows.md), and starts ISR
# with the same ports, mounts and env as the two sh installers. That agreement
# is asserted by `installer_parity_tests` in src/cloud_deploy.rs, so the three
# paths cannot drift apart in what they install.
#
#   Usage (PowerShell, Docker Desktop running):
#     .\install-windows.ps1                     # latest release
#     .\install-windows.ps1 -ReleaseTag v1.1.85
#
#   Auth: NOT REQUIRED for the default repo, whose releases are public. A token
#   only buys you GitHub's higher rate limit, or access to a private -Repo:
#     • `gh auth login` first (uses the GitHub CLI), OR
#     • $env:GITHUB_TOKEN = "<token>"

[CmdletBinding()]
param(
  [string]$ReleaseTag = "",
  # Where release binaries live. Override with -Repo <owner>/<repo> to install
  # from a fork or a mirror.
  #
  # NOT the update feed. ISR self-updates from a separate repo carrying SEALED
  # payloads, which this installer has no key to open — pointing -Repo at it
  # downloads bytes that cannot be unpacked.
  [string]$Repo = "M617263Kaplan/influxdb-smart-router",
  [string]$Name = "isr",
  [string]$Network = "isr-cluster-net",
  [string]$StateVolume = "isr-state",
  [int]$Port = 9800,
  [int]$ToolPort = 9843,
  [switch]$NoBrowser
)

$ErrorActionPreference = "Stop"
function Say($m)  { Write-Host "==> $m" -ForegroundColor Cyan }
function Warn($m) { Write-Host "!   $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "x   $m" -ForegroundColor Red; exit 1 }

# ── preconditions ────────────────────────────────────────────────────────────
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
  Die "Docker is not installed. Install Docker Desktop (docker.com), start it, and re-run."
}
docker info *> $null
if ($LASTEXITCODE -ne 0) { Die "Docker Desktop is not running. Start it and re-run." }

# THE NAMED-VOLUME RULE, ENFORCED. A StateVolume containing a path separator
# is a bind mount, and on Docker Desktop that routes every SQLite write
# through the filesystem-translation layer. ISR itself warns at boot when it
# lands on one; this installer simply refuses to set it up that way.
if ($StateVolume -match '[:\\/]') {
  Die "StateVolume must be a NAMED Docker volume (e.g. 'isr-state'), not a path. A C:\ bind mount puts the state DB on the 9p/virtiofs layer and everything slows to its pace — see docs/install-windows.md."
}

# ── auth ─────────────────────────────────────────────────────────────────────
$useGh = [bool](Get-Command gh -ErrorAction SilentlyContinue)
if ($useGh) {
  gh auth status *> $null
  if ($LASTEXITCODE -ne 0) { $useGh = $false }
}
# A MISSING TOKEN IS NOT FATAL. This refused on principle rather than trying:
# `Die "No GitHub auth…"` ran before the first request, so the anonymous path
# was unreachable and a public user never got as far as asking GitHub for
# anything. The release assets this installer wants are public.
#
# The mac and linux installers were fixed for this; nothing looked at this file
# because the guard in tests/public_install_path.rs read a hand-written pair of
# shell scripts. It now derives the list from the tree.
if (-not $useGh -and -not $env:GITHUB_TOKEN) {
  Say "No GitHub token - continuing anonymously (set GITHUB_TOKEN to raise GitHub's rate limit)."
}

# THE HALF THAT IS EASY TO MISS while removing the Die: a header hashtable
# written inline sends `Authorization: Bearer ` when the token is empty, and
# GitHub answers 401 to a malformed credential rather than treating the request
# as anonymous. That reads as "my token is wrong" on a public asset and sends
# people hunting for a token they do not need.
function Gh-Headers([string]$Accept) {
  $h = @{ Accept = $Accept }
  if ($env:GITHUB_TOKEN) { $h.Authorization = "Bearer $env:GITHUB_TOKEN" }
  return $h
}

# ── resolve the release and the amd64 tarball ────────────────────────────────
$api = "https://api.github.com/repos/$Repo"
$relUrl = if ($ReleaseTag) { "$api/releases/tags/$ReleaseTag" } else { "$api/releases/latest" }
Say "Resolving release…"
if ($useGh) {
  $rel = gh api ($relUrl -replace '^https://api.github.com/','') | ConvertFrom-Json
} else {
  $rel = Invoke-RestMethod -Uri $relUrl -Headers (Gh-Headers "application/vnd.github+json")
}
$tag = $rel.tag_name
$asset = $rel.assets | Where-Object { $_.name -like "*linux-amd64-image.tar.gz" } | Select-Object -First 1
if (-not $asset) { Die "release $tag has no linux-amd64 image tarball" }
Say "Release $tag — downloading $($asset.name) ($([math]::Round($asset.size/1MB))MB)…"

$tarball = Join-Path $env:TEMP $asset.name
if ($useGh) {
  gh release download $tag --repo $Repo --pattern $asset.name --output $tarball --clobber
  if ($LASTEXITCODE -ne 0) { Die "download failed" }
} else {
  # Asset downloads need the octet-stream accept header against the ASSET URL —
  # the browser_download_url 404s for private repos.
  Invoke-WebRequest -Uri $asset.url -OutFile $tarball -Headers (Gh-Headers "application/octet-stream")
}

# ── verify the tarball against the release's own SHA256SUMS.txt ──────────────
#
# THIS WAS MISSING ENTIRELY until the installer parity tests were written. Both
# sh installers refuse to `docker load` an image whose checksum does not match,
# and this one loaded whatever arrived — so the Windows front door, the newest
# and least-exercised path, was the one with no integrity check on a 150MB
# binary artefact pulled over the network and run as a privileged container.
#
# Nobody chose that. It is what "port the sh script" produces when the port is
# reviewed against what it does rather than against what the original does.
# That is the entire argument for asserting parity in the test suite instead of
# trusting three files to stay in step by attention.
#
# A skip is STATED, never silent: an operator who reads "verified" in the docs
# must not be reading about a step that quietly did nothing.
# AND THE HASH ALONE IS NOT ENOUGH, which is the second thing this path got
# wrong. SHA256SUMS.txt comes from the SAME release as the image: whoever can
# publish one publishes the other. Since v1.2.13 every release also carries
# SHA256SUMS.txt.sig — one Ed25519 signature over the manifest, against a key
# PINNED here rather than fetched. Verify that first, and the hash below becomes
# a real check instead of a checksum against the attacker's own arithmetic.
#
# WINDOWS HAS NO BUILT-IN Ed25519. .NET's System.Security.Cryptography does not
# implement it at any version this script can assume, so the verifier is either
# an openssl.exe on this machine (Git for Windows ships one) or the ISR image
# already installed here. If neither exists this REFUSES, exactly as the two sh
# installers do — the previous behaviour of loading a 150 MB privileged image
# unchecked is the thing being removed.
$RELEASE_SIGNING_PUBKEY_PEM = @"
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA5OLkhumKj2HNdvnAgsUA1/Z7TQlmL43K1FjqvcjA3iw=
-----END PUBLIC KEY-----
"@
# A known-good signature over a fixed message, so "this openssl cannot do
# Ed25519" is never reported as "your download was tampered with" — the two exit
# the same way.
$SELFTEST_SIG_B64 = 'acyn8EQz+Z3eFcEa831oqpfU97RgN/aCc8excp2cxGCxH96DayZr9+3pN7LgIs/hWnFEgG12CoOzEGYMjMa1Aw=='

function Get-ManifestMessage([string]$Version, [string]$ManifestPath, [string]$OutPath) {
  $h = (Get-FileHash -Path $ManifestPath -Algorithm SHA256).Hash.ToLower()
  $v = $Version -replace '^v', ''
  # LF line endings and no BOM: the signer emits exactly these bytes, and
  # PowerShell's default here would be CRLF + BOM, which verifies nowhere.
  $text = "ISR-RELEASE-MANIFEST-v1`nversion=$v`nsha256=$h`n"
  [System.IO.File]::WriteAllBytes($OutPath, [System.Text.Encoding]::ASCII.GetBytes($text))
}

function Test-OpensslVerifies([string]$Exe, [string]$PemPath, [string]$MsgPath, [string]$SigPath) {
  & $Exe pkeyutl -verify -pubin -inkey $PemPath -rawin -in $MsgPath -sigfile $SigPath 2>$null 1>$null
  return ($LASTEXITCODE -eq 0)
}

function Find-Verifier([string]$PemPath) {
  $candidates = @()
  if ($env:ISR_OPENSSL) { $candidates += $env:ISR_OPENSSL }
  $candidates += @("openssl.exe", "openssl",
                   "$env:ProgramFiles\Git\usr\bin\openssl.exe",
                   "${env:ProgramFiles(x86)}\Git\usr\bin\openssl.exe",
                   "$env:ProgramFiles\OpenSSL-Win64\bin\openssl.exe")
  $d = Join-Path $env:TEMP "isr-verifier-selftest"
  New-Item -ItemType Directory -Force -Path $d | Out-Null
  $m = Join-Path $d "m"; $msg = Join-Path $d "msg"; $sig = Join-Path $d "sig"
  [System.IO.File]::WriteAllBytes($m, [System.Text.Encoding]::ASCII.GetBytes("isr-verifier-selftest`n"))
  [System.IO.File]::WriteAllBytes($sig, [Convert]::FromBase64String($SELFTEST_SIG_B64))
  Get-ManifestMessage "0.0.0-selftest" $m $msg
  foreach ($c in $candidates) {
    if (-not $c) { continue }
    $resolved = (Get-Command $c -ErrorAction SilentlyContinue)
    $exe = if ($resolved) { $resolved.Source } elseif (Test-Path $c) { $c } else { $null }
    if (-not $exe) { continue }
    if (Test-OpensslVerifies $exe $PemPath $msg $sig) { return $exe }
  }
  return $null
}

$sumsAsset = $rel.assets | Where-Object { $_.name -eq "SHA256SUMS.txt" }     | Select-Object -First 1
$sigAsset  = $rel.assets | Where-Object { $_.name -eq "SHA256SUMS.txt.sig" } | Select-Object -First 1
$manifestTrusted = $false
$sumsFile = Join-Path $env:TEMP "isr-SHA256SUMS.txt"
$sigFile  = Join-Path $env:TEMP "isr-SHA256SUMS.txt.sig"

function Refuse-Unverified([string]$What, [string]$Fix) {
  if ($env:ISR_ALLOW_UNVERIFIED -eq "1") {
    Warn "=============================================================="
    Warn "INSTALLING AN UNVERIFIED IMAGE — ISR_ALLOW_UNVERIFIED=1 is set."
    Warn $What
    Warn "This image could have been substituted in transit, and it is"
    Warn "loaded as a privileged container with the Docker socket."
    Warn "=============================================================="
    return
  }
  Remove-Item $tarball -Force -ErrorAction SilentlyContinue
  Die "REFUSING TO INSTALL — the release could not be verified.`n     $What`n     $Fix`n     If you accept the risk, re-run with `$env:ISR_ALLOW_UNVERIFIED=`"1`"."
}

if (-not $sumsAsset -or -not $sigAsset) {
  Refuse-Unverified "Release $tag publishes no signed manifest (needs both SHA256SUMS.txt and SHA256SUMS.txt.sig)." `
                    "Releases are signed from v1.2.13 onward; an earlier release cannot be verified by this installer."
} else {
  try {
    if ($useGh) {
      gh release download $tag --repo $Repo --pattern SHA256SUMS.txt     --output $sumsFile --clobber
      if ($LASTEXITCODE -ne 0) { throw "gh could not download SHA256SUMS.txt" }
      gh release download $tag --repo $Repo --pattern SHA256SUMS.txt.sig --output $sigFile --clobber
      if ($LASTEXITCODE -ne 0) { throw "gh could not download SHA256SUMS.txt.sig" }
    } else {
      Invoke-WebRequest -Uri $sumsAsset.url -OutFile $sumsFile -Headers (Gh-Headers "application/octet-stream")
      Invoke-WebRequest -Uri $sigAsset.url -OutFile $sigFile -Headers (Gh-Headers "application/octet-stream")
    }
  } catch {
    Remove-Item $tarball -Force -ErrorAction SilentlyContinue
    Die "Could not download the signed manifest for $tag ($($_.Exception.Message)). Nothing has been installed."
  }

  $pemFile = Join-Path $env:TEMP "isr-release-pubkey.pem"
  [System.IO.File]::WriteAllBytes($pemFile, [System.Text.Encoding]::ASCII.GetBytes($RELEASE_SIGNING_PUBKEY_PEM))
  $msgFile = Join-Path $env:TEMP "isr-manifest.msg"
  Get-ManifestMessage $tag $sumsFile $msgFile

  $verifier = Find-Verifier $pemFile
  if ($verifier) {
    if (Test-OpensslVerifies $verifier $pemFile $msgFile $sigFile) {
      Say "Release signature verified for $tag ($verifier)."
      $manifestTrusted = $true
    } else {
      # NOT overridable. The verifier proved itself on a known vector first, so
      # this is the signature genuinely failing, not an old tool.
      Remove-Item $tarball -Force -ErrorAction SilentlyContinue
      Die "SIGNATURE INVALID for release $tag.`n`n     The manifest downloaded from $Repo is NOT the one InfluxData signed for`n     this version — either it was modified in transit, or it belongs to a`n     different release being served in place of this one.`n`n     Nothing has been installed. Do not re-run with ISR_ALLOW_UNVERIFIED=1 to`n     get past this — that flag is for a host that cannot verify, not for a`n     release that failed to."
    }
  } else {
    # Second verifier: the ISR already installed here. Verifying the NEW
    # download with the NEW binary would be circular; with the OLD one it is not.
    $existing = (docker inspect --format '{{.Config.Image}}' $Name 2>$null)
    if ($LASTEXITCODE -eq 0 -and $existing) {
      docker run --rm -v "$($env:TEMP):/verify:ro" --entrypoint /usr/local/bin/isr $existing `
        verify-manifest --manifest /verify/isr-SHA256SUMS.txt --sig /verify/isr-SHA256SUMS.txt.sig --version ($tag -replace '^v','') 2>$null 1>$null
      if ($LASTEXITCODE -eq 0) {
        Say "Release signature verified for $tag by the ISR already installed here."
        $manifestTrusted = $true
      }
    }
    if (-not $manifestTrusted) {
      Refuse-Unverified "No tool on this machine can verify an Ed25519 signature (looked for openssl.exe, including the one Git for Windows ships; each was checked against a known-good signature first)." `
                        "Install OpenSSL, or Git for Windows, and re-run. Point `$env:ISR_OPENSSL at it if it is somewhere unusual."
    }
  }
}

# The hash, now checked against a manifest that is TRUSTED rather than merely
# downloaded. Lines are "<hash>  <name>"; match on the asset's own name so a
# release holding several tarballs cannot verify one against another's hash.
if ($manifestTrusted) {
  $want = (Get-Content $sumsFile |
           Where-Object { $_ -match "\s+$([regex]::Escape($asset.name))\s*$" } |
           Select-Object -First 1) -replace '\s.*$', ''
  if (-not $want) {
    Remove-Item $tarball -Force -ErrorAction SilentlyContinue
    Die "The signed manifest for $tag has no entry for $($asset.name) — the release is incomplete. Nothing has been installed."
  }
  $got = (Get-FileHash -Path $tarball -Algorithm SHA256).Hash
  if ($got -ieq $want) {
    Say "Image checksum verified against the signed manifest."
  } else {
    Remove-Item $tarball -Force -ErrorAction SilentlyContinue
    Die "Image checksum MISMATCH against the SIGNED manifest for $tag — refusing to load a corrupt/tampered image.`n     expected $want`n     got      $got"
  }
}

# ── load, and resolve the image name FROM THE LOAD OUTPUT ────────────────────
# `docker save` bakes the tag into the tarball (the v1.1.39 lesson lives in
# release-images.sh) — read what load says rather than reconstructing it.
Say "Loading image…"
$loadOut = docker load -i $tarball
if ($LASTEXITCODE -ne 0) { Die "docker load failed" }
$image = ($loadOut | Select-String 'Loaded image:\s*(\S+)').Matches.Groups[1].Value
if (-not $image) { Die "could not read the image name from docker load output: $loadOut" }
Say "Loaded $image"

# ── network, volume, container ───────────────────────────────────────────────
docker network inspect $Network *> $null
if ($LASTEXITCODE -ne 0) { docker network create $Network | Out-Null }
docker volume inspect $StateVolume *> $null
$freshState = $LASTEXITCODE -ne 0
if ($freshState) { docker volume create $StateVolume | Out-Null; Say "Created named volume '$StateVolume' (ext4 inside the VM — full speed)" }
else { Warn "Volume '$StateVolume' already exists — keeping its state (admin account, tokens, journal). Remove it first for a truly fresh install." }

# CARRY THE OLD CONTAINER'S ISR_* ENVIRONMENT FORWARD, read BEFORE the remove.
#
# This script replayed its own fixed template on every reinstall, so an upgrade
# silently dropped every variable an operator had added. install-mac.sh and
# install-linux.sh both fixed that after it happened live on 2026-08-16 — it
# cost a connected Traffic Lab its channel and its agent image in one stroke —
# and the fix was never ported here. Same defect, one platform behind.
#
# THE EXCLUSION LIST IS THIS TEMPLATE'S OWN VARIABLES, AND ONLY THOSE. It is
# deliberately NOT a copy of the Unix scripts': they also set
# ISR_ENCRYPTION_KEY_FILE and therefore exclude it, while this one does not set
# it at all. Excluding it here would drop an operator's encryption-at-rest
# configuration on every Windows upgrade — a different bug wearing the first
# one's clothes.
$keepEnv = @()
$existingEnv = docker inspect $Name --format '{{range .Config.Env}}{{println .}}{{end}}' 2>$null
if ($LASTEXITCODE -eq 0 -and $existingEnv) {
  $keepEnv = @($existingEnv -split "`n" |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -like 'ISR_*' } |
    Where-Object { $_ -notmatch '^ISR_(LISTEN|DATA_LISTEN|STATE_DB|WRITE_QUEUE_PATH)=' })
  if ($keepEnv.Count -gt 0) {
    $names = ($keepEnv | ForEach-Object { ($_ -split '=')[0] }) -join ' '
    Say "  Carrying forward from the old container: $names"
  }
}

docker rm -f $Name *> $null

Say "Starting ISR…"
# Built as an array and splatted, so the carried-forward variables can be
# appended. A backtick-continued literal cannot take a variable number of -e
# flags, which is part of why they were dropped here in the first place.
$runArgs = @(
  'run', '-d', '--name', $Name, '--network', $Network, '--restart', 'unless-stopped',
  '-p', "${Port}:9800", '-p', '8086:8086', '-p', '8181:8181', '-p', "${ToolPort}:9843",
  '-v', '/var/run/docker.sock:/var/run/docker.sock',
  '-v', "${StateVolume}:/var/lib/isr",
  '-e', 'ISR_LISTEN=0.0.0.0:9800',
  '-e', 'ISR_DATA_LISTEN=0.0.0.0:8086,0.0.0.0:8181',
  '-e', 'ISR_STATE_DB=/var/lib/isr/state.db',
  '-e', 'ISR_WRITE_QUEUE_PATH=/var/lib/isr/write-queue.jsonl'
)
foreach ($e in $keepEnv) { $runArgs += @('-e', $e) }
$runArgs += $image
docker @runArgs | Out-Null
if ($LASTEXITCODE -ne 0) { Die "docker run failed" }
docker network connect bridge $Name *> $null

# ── readiness ────────────────────────────────────────────────────────────────
Say "Waiting for ISR to answer…"
$up = $false
for ($i = 0; $i -lt 60; $i++) {
  try {
    $h = Invoke-RestMethod -Uri "http://localhost:$Port/api/isr/admins/bootstrap-status" -TimeoutSec 2
    $up = $true; break
  } catch { Start-Sleep -Seconds 2 }
}
if (-not $up) { Die "ISR did not answer on port $Port within 2 minutes — 'docker logs $Name' has the story." }

$console = "http://localhost:$Port"
Say "ISR is up: $console"
if ($h.needs_bootstrap) {
  Say "First run — the console will ask you to create the administrator."
  Say "The Create button disarms while it works; give the first boot a moment."
} else {
  Say "This volume already has an administrator — sign in with its credentials."
}
if (-not $NoBrowser) { Start-Process $console }
