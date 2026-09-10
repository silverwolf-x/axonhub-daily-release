param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ArgsFromCmd
)

. (Join-Path $PSScriptRoot 'axonhub-common.ps1')

function Show-Usage {
  Write-Host @"
Usage: stop.bat [--force]

Stops the AxonHub process started from $BinaryPath.
Options:
  --force        Stop every axonhub.exe process, wherever it was started from
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
}
