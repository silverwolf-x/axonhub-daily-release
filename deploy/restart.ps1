param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ArgsFromCmd
)

. (Join-Path $PSScriptRoot 'axonhub-common.ps1')

function Show-Usage {
  Write-Host @"
Usage: restart.bat [--force]

Restarts AxonHub by stopping and starting it.
Options:
  --force        Stop every axonhub.exe process before starting
  -v, --verbose  Print debug logs
  -h, --help     Show this help
"@
}

$All = $false
foreach($a in $ArgsFromCmd){
  switch -Regex ($a){
    '^(--force|-f)$' { $All = $true; continue }
    '^(--verbose|-v)$' { $VerboseFlag = $true; continue }
    '^(--help|-h)$' { Show-Usage; exit 0 }
    default { Write-Err "Unknown option: $a"; Show-Usage; exit 2 }
  }
}

Invoke-AxonHubScript {
  Stop-AxonHub -All:$All
  Start-AxonHub
}
