param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ArgsFromCmd
)

. (Join-Path $PSScriptRoot 'axonhub-common.ps1')

function Show-Usage {
  Write-Host @"
Usage: start.bat [--verbose]

Starts AxonHub in the background (no service manager).
Binary:   $BinaryPath
Logs:     $LogDir
PID file: $PidFile
"@
}

foreach($a in $ArgsFromCmd){
  switch -Regex ($a){
    '^(--verbose|-v)$' { $VerboseFlag = $true; continue }
    '^(--help|-h)$' { Show-Usage; exit 0 }
    default { Write-Err "Unknown option: $a"; Show-Usage; exit 2 }
  }
}

Invoke-AxonHubScript {
  Start-AxonHub
}
