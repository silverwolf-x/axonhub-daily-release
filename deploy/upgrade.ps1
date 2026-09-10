param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ArgsFromCmd
)

. (Join-Path $PSScriptRoot 'axonhub-common.ps1')

function Show-Usage {
  Write-Host @"
AxonHub Upgrade Script (Windows)

Source: $AxonHubRepo
Usage: upgrade.bat [options] [version]

Options:
  -y, --yes         Upgrade without asking for confirmation
  -f, --force       Reinstall even if already on the target version
  -c, --check       Only report the available version; change nothing
      --stable      Consider stable releases only
  -p, --prerelease  Include prereleases (default; -b/--beta and -r/--rc are aliases)
  -v, --verbose     Print debug logs
  -h, --help        Show this help

Examples:
  upgrade.bat                       Check and prompt for upgrade
  upgrade.bat --check               Only check for updates
  upgrade.bat -y                    Upgrade without confirmation
  upgrade.bat v1.0.0-beta12-rc16    Install a specific version
"@
}

$IncludePrerelease = $true
$CheckOnly = $false
$Force = $false
$Yes = $false
$Version = ''

foreach($a in $ArgsFromCmd){
  switch -Regex ($a){
    '^(--yes|-y)$' { $Yes = $true; continue }
    '^(--force|-f)$' { $Force = $true; continue }
    '^(--check|-c)$' { $CheckOnly = $true; continue }
    '^--stable$' { $IncludePrerelease = $false; continue }
    '^(--prerelease|-p|--beta|-b|--rc|-r)$' { $IncludePrerelease = $true; continue }
    '^(--verbose|-v)$' { $VerboseFlag = $true; continue }
    '^(--help|-h)$' { Show-Usage; exit 0 }
    '^[vV]?\d+\.\d+\.\d+' { $Version = $a; continue }
    default { Write-Err "Unknown option: $a"; Show-Usage; exit 2 }
  }
}

Invoke-AxonHubScript {
  if(-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)){
    throw "AxonHub is not installed at $BinaryPath. Run install.bat first."
  }

  $current = Get-BinaryVersion $BinaryPath
  if($current){ Write-Info "Current version: $current" } else { Write-Warn 'Could not determine the current version' }

  $release = Get-AxonHubRelease $Version $IncludePrerelease
  $target = [string]$release.tag_name
  Write-Info "Target version:  $target"

  $needsUpgrade = (-not $current) -or ((Compare-Version $current $target) -lt 0)
  # An explicitly requested version is installed even when it is older.
  if($Version -and $current -ne $target){ $needsUpgrade = $true }

  if($CheckOnly){
    if($needsUpgrade){
      Write-Success "Update available: $current -> $target"
      Write-Info "Download URL: $((Get-ReleaseArchive $release).browser_download_url)"
    } else {
      Write-Success "AxonHub is up to date ($current)"
    }
    return
  }

  if(-not $needsUpgrade -and -not $Force){
    Write-Success "AxonHub is up to date ($current)"
    return
  }

  if(-not $Yes){
    $reply = Read-Host "Upgrade AxonHub from $current to ${target}? [y/N]"
    if($reply -notmatch '^[Yy]'){
      Write-Info 'Upgrade cancelled'
      return
    }
  }

  Install-AxonHubRelease $release
  Start-AxonHubOrRollback
  Write-Success "Upgrade completed: $current -> $(Get-BinaryVersion $BinaryPath)"
}
