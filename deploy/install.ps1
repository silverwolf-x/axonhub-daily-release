param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ArgsFromCmd
)

. (Join-Path $PSScriptRoot 'axonhub-common.ps1')

function Show-Usage {
  Write-Host @"
AxonHub Installer (Windows)

Source:  $AxonHubRepo
Target:  $BaseDir
Usage:   install.bat [options] [version]

Options:
      --stable      Consider stable releases only
  -p, --prerelease  Include prereleases (default; -b/--beta and -r/--rc are aliases)
  -v, --verbose     Print debug logs
  -h, --help        Show this help

Environment:
  AXONHUB_VERSION   Version to install when none is given
  AXONHUB_HOME      Install directory (default: %LOCALAPPDATA%\AxonHub)
  GITHUB_TOKEN      Optional token to avoid GitHub API rate limits
"@
}

$IncludePrerelease = $true
$Version = $env:AXONHUB_VERSION

foreach($a in $ArgsFromCmd){
  switch -Regex ($a){
    '^--stable$' { $IncludePrerelease = $false; continue }
    '^(--prerelease|-p|--beta|-b|--rc|-r)$' { $IncludePrerelease = $true; continue }
    '^(--verbose|-v)$' { $VerboseFlag = $true; continue }
    '^(--help|-h)$' { Show-Usage; exit 0 }
    '^[vV]?\d+\.\d+\.\d+' { $Version = $a; continue }
    default { Write-Err "Unknown option: $a"; Show-Usage; exit 2 }
  }
}

function New-DefaultConfig {
  $base = $BaseDir -replace '\\', '/'
  @"
server:
  port: $DefaultPort
  name: "AxonHub"
  debug: false

db:
  dialect: "sqlite3"
  dsn: "$base/axonhub.db?cache=shared&_fk=1&_pragma=journal_mode(WAL)"

cache:
  mode: "memory"
  memory:
    expiration: "5s"
    cleanup_interval: "5s"

log:
  level: "info"
  encoding: "json"
  output: "file"
  file:
    path: "$base/logs/axonhub.log"
    max_size: 100
    max_age: 30
    max_backups: 10
    local_time: true
"@ | Set-Content -LiteralPath $ConfigFile -Encoding Ascii
}

Invoke-AxonHubScript {
  Write-Info "Installing AxonHub into $BaseDir"
  $wasRunning = @(Get-AxonHubProcesses).Count -gt 0

  $release = Get-AxonHubRelease $Version $IncludePrerelease
  Install-AxonHubRelease $release

  if(-not (Test-Path -LiteralPath $ConfigFile -PathType Leaf)){
    Write-Info "Creating default configuration: $ConfigFile"
    New-DefaultConfig
  }

  if($wasRunning){
    Start-AxonHubOrRollback
  }

  Write-Success 'AxonHub installation completed!'
  Write-Host ''
  Write-Host 'Next steps:'
  Write-Host "  1. Edit configuration: $ConfigFile"
  Write-Host "  2. Start AxonHub:      $BaseDir\start.bat"
  Write-Host "  3. Stop AxonHub:       $BaseDir\stop.bat"
  Write-Host "  4. Upgrade AxonHub:    $BaseDir\upgrade.bat"
  Write-Host "  5. Web interface:      http://localhost:$(Get-ConfiguredPort)"
}
