# Shared helpers for the AxonHub Windows scripts.
# Dot-source it from a sibling script: . (Join-Path $PSScriptRoot 'axonhub-common.ps1')
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts with the ANSI code page.

$ErrorActionPreference = 'Stop'
# The Invoke-WebRequest progress bar slows downloads down by an order of magnitude on PowerShell 5.1.
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$AxonHubRepo = if($env:AXONHUB_REPO){ $env:AXONHUB_REPO } else { 'silverwolf-x/axonhub-daily-release' }
$AxonHubApi = "https://api.github.com/repos/$AxonHubRepo"

$BaseDir = if($env:AXONHUB_HOME){ $env:AXONHUB_HOME } else { Join-Path $env:LOCALAPPDATA 'AxonHub' }
$BinaryPath = Join-Path $BaseDir 'axonhub.exe'
$BackupBinaryPath = Join-Path $BaseDir 'axonhub.exe.old'
$ConfigFile = Join-Path $BaseDir 'config.yml'
$PidFile = Join-Path $BaseDir 'axonhub.pid'
$LogDir = Join-Path $BaseDir 'logs'
$StdoutLog = Join-Path $LogDir 'stdout.log'
$StderrLog = Join-Path $LogDir 'stderr.log'
$DefaultPort = 8090

# Files shipped next to axonhub.exe in the release archive and kept in sync by install/upgrade.
$ManagedFiles = @(
  'axonhub-common.ps1',
  'install.ps1', 'start.ps1', 'stop.ps1', 'restart.ps1', 'upgrade.ps1',
  'install.bat', 'start.bat', 'stop.bat', 'restart.bat', 'upgrade.bat',
  'CHANGELOG.md', 'LICENSE'
)

$VerboseFlag = $false

function Write-Info([string]$m){ Write-Host "[INFO] $m" -ForegroundColor Cyan }
function Write-Success([string]$m){ Write-Host "[SUCCESS] $m" -ForegroundColor Green }
function Write-Warn([string]$m){ Write-Host "[WARNING] $m" -ForegroundColor Yellow }
function Write-Err([string]$m){ Write-Host "[ERROR] $m" -ForegroundColor Red }
function Write-Dbg([string]$m){ if($VerboseFlag){ Write-Host "[DEBUG] $m" -ForegroundColor DarkGray } }

# Runs a script body and turns any terminating error into a readable message plus exit code 1.
function Invoke-AxonHubScript([scriptblock]$Body){
  try {
    & $Body
  } catch {
    Write-Err $_.Exception.Message
    Write-Dbg $_.ScriptStackTrace
    exit 1
  }
  exit 0
}

function Ensure-Dir([string]$path){
  if(-not (Test-Path -LiteralPath $path -PathType Container)){
    New-Item -ItemType Directory -Force -Path $path | Out-Null
  }
}

function Test-SamePath([string]$a, [string]$b){
  if(-not $a -or -not $b){ return $false }
  return [string]::Equals([IO.Path]::GetFullPath($a), [IO.Path]::GetFullPath($b), [StringComparison]::OrdinalIgnoreCase)
}

function Get-Platform {
  switch ("$env:PROCESSOR_ARCHITECTURE".ToLowerInvariant()){
    'amd64' { return 'windows_amd64' }
    'arm64' { return 'windows_arm64' }
    default { throw "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE" }
  }
}

# Plain .NET instead of Get-FileHash/Expand-Archive: those live in script modules that
# fail to load in some Windows PowerShell 5.1 environments.
function Get-Sha256([string]$path){
  $sha = [Security.Cryptography.SHA256]::Create()
  $stream = [IO.File]::OpenRead($path)
  try {
    return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '')
  } finally {
    $stream.Dispose()
    $sha.Dispose()
  }
}

function Get-BinaryVersion([string]$path){
  if(-not (Test-Path -LiteralPath $path -PathType Leaf)){ return '' }
  try {
    $out = & $path version 2>$null
    if($LASTEXITCODE -eq 0 -and $out){ return ([string]@($out)[0]).Trim() }
  } catch {}
  return ''
}

# ---------------------------------------------------------------------------
# Process management
# ---------------------------------------------------------------------------

function Get-PidFromFile {
  if(-not (Test-Path -LiteralPath $PidFile -PathType Leaf)){ return $null }
  $raw = Get-Content -LiteralPath $PidFile -Raw -ErrorAction SilentlyContinue
  if("$raw" -match '^\s*(\d+)\s*$'){ return [int]$Matches[1] }
  return $null
}

# Returns the AxonHub processes started from $BinaryPath. Other axonhub.exe copies
# (dev builds, other installs) are left alone unless -All is given.
function Get-AxonHubProcesses([switch]$All){
  $found = @{}
  foreach($p in @(Get-Process -Name 'axonhub' -ErrorAction SilentlyContinue)){
    if($All -or (Test-SamePath $p.Path $BinaryPath)){ $found[$p.Id] = $p }
  }
  $filePid = Get-PidFromFile
  if($filePid -and -not $found.ContainsKey($filePid)){
    # Windows recycles PIDs, so only trust the PID file while it still names an AxonHub process.
    # Path is empty when the process runs elevated, so accept the name match in that case.
    $p = Get-Process -Id $filePid -ErrorAction SilentlyContinue
    if($p -and $p.ProcessName -eq 'axonhub' -and (-not $p.Path -or (Test-SamePath $p.Path $BinaryPath))){
      $found[$p.Id] = $p
    }
  }
  return @($found.Values)
}

function Stop-AxonHub([switch]$All, [int]$TimeoutSeconds = 20){
  $procs = @(Get-AxonHubProcesses -All:$All)
  if($procs.Count -eq 0){
    Write-Info 'AxonHub is not running'
    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    return
  }

  foreach($p in $procs){
    Write-Info "Stopping AxonHub (PID: $($p.Id))..."
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
  }

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while($true){
    $alive = @($procs | Where-Object { Get-Process -Id $_.Id -ErrorAction SilentlyContinue })
    if($alive.Count -eq 0){ break }
    if((Get-Date) -gt $deadline){
      throw "AxonHub did not exit within $TimeoutSeconds seconds (PID: $(@($alive.Id) -join ', '))"
    }
    Start-Sleep -Milliseconds 300
  }

  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
  Write-Success 'AxonHub stopped'
}

function Get-ConfiguredPort {
  $port = $DefaultPort
  if(Test-Path -LiteralPath $BinaryPath -PathType Leaf){
    # The binary looks for config.yml in its working directory.
    Push-Location -LiteralPath $BaseDir
    try {
      $out = & $BinaryPath config get server.port 2>$null
      $value = ([string]@($out)[0]).Trim()
      if($LASTEXITCODE -eq 0 -and $value -match '^\d+$'){ $port = [int]$value }
    } catch {
      Write-Dbg "Could not read server.port: $($_.Exception.Message)"
    } finally {
      Pop-Location
    }
  }
  return $port
}

# Returns the PIDs listening on a TCP port. Only LISTEN sockets count: the TIME_WAIT
# entries left behind by a just-stopped instance must not block a restart.
function Get-PortListeners([int]$port){
  try {
    return @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue |
      Select-Object -ExpandProperty OwningProcess -Unique)
  } catch {
    Write-Dbg "Get-NetTCPConnection unavailable, using netstat: $($_.Exception.Message)"
  }
  # netstat state names are localized, so detect listeners by their wildcard remote address.
  $owners = @()
  foreach($line in @(netstat -ano)){
    if($line -match "^\s*TCP\s+\S+:$port\s+(0\.0\.0\.0:0|\[::\]:0)\s+\S+\s+(\d+)\s*$"){
      $owners += [int]$Matches[2]
    }
  }
  return @($owners | Select-Object -Unique)
}

function Show-StartupLogs {
  foreach($file in @($StderrLog, $StdoutLog)){
    if((Test-Path -LiteralPath $file -PathType Leaf) -and (Get-Item -LiteralPath $file).Length -gt 0){
      Write-Info "Last lines of ${file}:"
      Get-Content -LiteralPath $file -Tail 20 | Write-Host
    }
  }
}

function Start-AxonHub([int]$TimeoutSeconds = 60){
  if(-not (Test-Path -LiteralPath $BinaryPath -PathType Leaf)){
    throw "AxonHub binary not found at $BinaryPath. Run install.bat first."
  }

  $running = @(Get-AxonHubProcesses)
  if($running.Count -gt 0){
    Write-Warn "AxonHub is already running (PID: $(@($running.Id) -join ', '))"
    return
  }
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue

  $port = Get-ConfiguredPort
  $listeners = @(Get-PortListeners $port)
  if($listeners.Count -gt 0){
    throw "Port $port is already in use (PID: $($listeners -join ', '))"
  }

  if(Test-Path -LiteralPath $ConfigFile -PathType Leaf){
    Write-Info "Using configuration: $ConfigFile"
  } else {
    Write-Warn "Configuration not found at $ConfigFile, starting with defaults"
  }

  Ensure-Dir $LogDir
  Write-Info "Starting AxonHub $(Get-BinaryVersion $BinaryPath)..."
  $p = Start-Process -FilePath $BinaryPath -WorkingDirectory $BaseDir -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog
  # Touch the handle so ExitCode stays readable after the process exits.
  $null = $p.Handle
  Set-Content -LiteralPath $PidFile -Value $p.Id -Encoding Ascii

  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while($true){
    if($p.HasExited){
      Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
      Show-StartupLogs
      throw "AxonHub exited during startup (exit code: $($p.ExitCode))"
    }
    if(@(Get-PortListeners $port) -contains $p.Id){ break }
    if((Get-Date) -gt $deadline){
      Write-Warn "AxonHub is running but not listening on port $port after $TimeoutSeconds seconds; check the logs"
      break
    }
    Start-Sleep -Milliseconds 500
  }

  Write-Success "AxonHub started (PID: $($p.Id))"
  Write-Host "  - Web interface: http://localhost:$port"
  Write-Host "  - Logs:          $LogDir"
  Write-Host "  - PID file:      $PidFile"
}

# ---------------------------------------------------------------------------
# Versions
# ---------------------------------------------------------------------------

function Parse-SemVer([string]$version){
  if([string]::IsNullOrWhiteSpace($version)){ return $null }
  $m = [regex]::Match(
    ($version.Trim() -replace '^[vV]', ''),
    '^([0-9]+)\.([0-9]+)\.([0-9]+)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z.-]+)?$'
  )
  if(-not $m.Success){ return $null }
  $pre = @()
  if($m.Groups[4].Success){ $pre = @($m.Groups[4].Value -split '\.') }
  return [pscustomobject]@{
    Major = [long]$m.Groups[1].Value
    Minor = [long]$m.Groups[2].Value
    Patch = [long]$m.Groups[3].Value
    PreRelease = $pre
  }
}

# Compares two identifiers by splitting them into digit and non-digit runs, so that
# compound tags order naturally: beta8-rc13 < beta11-rc9 < beta11-rc22.
function Compare-NaturalId([string]$a, [string]$b){
  $aParts = @([regex]::Matches($a, '[0-9]+|[^0-9]+') | ForEach-Object { $_.Value })
  $bParts = @([regex]::Matches($b, '[0-9]+|[^0-9]+') | ForEach-Object { $_.Value })
  for($i = 0; $i -lt [Math]::Max($aParts.Count, $bParts.Count); $i++){
    if($i -ge $aParts.Count){ return -1 }
    if($i -ge $bParts.Count){ return 1 }
    $x = [string]$aParts[$i]
    $y = [string]$bParts[$i]
    $xNum = $x -match '^[0-9]+$'
    $yNum = $y -match '^[0-9]+$'
    if($xNum -and $yNum){
      # Compare lengths before text to avoid overflow on long numeric runs.
      $x = $x.TrimStart([char]'0')
      $y = $y.TrimStart([char]'0')
      if($x.Length -ne $y.Length){ return [Math]::Sign($x.Length - $y.Length) }
    } elseif($xNum -ne $yNum){
      # SemVer: numeric identifiers sort before alphanumeric ones.
      if($xNum){ return -1 } else { return 1 }
    }
    $cmp = [string]::CompareOrdinal($x, $y)
    if($cmp -ne 0){ return [Math]::Sign($cmp) }
  }
  return 0
}

function Compare-Version([string]$a, [string]$b){
  $va = Parse-SemVer $a
  $vb = Parse-SemVer $b
  if($null -eq $va -or $null -eq $vb){
    if($null -eq $va -and $null -eq $vb){ return [Math]::Sign([string]::Compare($a, $b, [StringComparison]::OrdinalIgnoreCase)) }
    if($null -eq $va){ return -1 } else { return 1 }
  }

  foreach($field in 'Major', 'Minor', 'Patch'){
    if($va.$field -ne $vb.$field){ return [Math]::Sign($va.$field - $vb.$field) }
  }

  $aPre = @($va.PreRelease)
  $bPre = @($vb.PreRelease)
  # A normal release has higher precedence than any prerelease.
  if($aPre.Count -eq 0 -or $bPre.Count -eq 0){ return [Math]::Sign($bPre.Count - $aPre.Count) }

  for($i = 0; $i -lt [Math]::Max($aPre.Count, $bPre.Count); $i++){
    if($i -ge $aPre.Count){ return -1 }
    if($i -ge $bPre.Count){ return 1 }
    $cmp = Compare-NaturalId $aPre[$i] $bPre[$i]
    if($cmp -ne 0){ return $cmp }
  }
  return 0
}

# ---------------------------------------------------------------------------
# Releases
# ---------------------------------------------------------------------------

function Invoke-GitHubApi([string]$path){
  $headers = @{
    'Accept' = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2022-11-28'
    'User-Agent' = 'axonhub-windows-scripts'
  }
  if($env:GITHUB_TOKEN){ $headers['Authorization'] = "Bearer $env:GITHUB_TOKEN" }
  return Invoke-RestMethod -Method Get -Uri "$AxonHubApi$path" -Headers $headers
}

function Select-LatestRelease([object[]]$releases, [bool]$IncludePrerelease){
  $best = $null
  foreach($r in $releases){
    $parsed = Parse-SemVer ([string]$r.tag_name)
    if($r.draft -or $null -eq $parsed){ continue }
    $isPre = [bool]$r.prerelease -or @($parsed.PreRelease).Count -gt 0
    if($isPre -and -not $IncludePrerelease){ continue }
    if($null -eq $best -or (Compare-Version $r.tag_name $best.tag_name) -gt 0){ $best = $r }
  }
  return $best
}

# Builds a release object from GoReleaser's naming scheme, for use when the API is unavailable.
function New-ReleaseFromTag([string]$tag){
  $download = "https://github.com/$AxonHubRepo/releases/download/$tag"
  $zip = "axonhub_$($tag -replace '^[vV]', '')_$(Get-Platform).zip"
  return [pscustomobject]@{
    tag_name = $tag
    draft = $false
    prerelease = $false
    assets = @(
      [pscustomobject]@{ name = $zip; browser_download_url = "$download/$zip"; digest = '' },
      [pscustomobject]@{ name = 'checksums.txt'; browser_download_url = "$download/checksums.txt"; digest = '' }
    )
  }
}

# The Atom feed is not subject to the API rate limit and lists the 10 newest releases.
function Get-ReleasesFromFeed {
  $feed = (Invoke-WebRequest -Uri "https://github.com/$AxonHubRepo/releases.atom" -UseBasicParsing).Content
  $tags = [regex]::Matches($feed, '/releases/tag/([^"<>/]+)"') | ForEach-Object { [uri]::UnescapeDataString($_.Groups[1].Value) }
  return @($tags | Select-Object -Unique | ForEach-Object { New-ReleaseFromTag $_ })
}

# Returns the release for $Version, or the highest SemVer release when $Version is empty.
# Falls back to github.com download URLs when the API fails (usually its 60 requests/hour limit).
function Get-AxonHubRelease([string]$Version, [bool]$IncludePrerelease = $true){
  if($Version){
    $tag = if($Version -match '^[vV]'){ $Version } else { "v$Version" }
    Write-Info "Fetching release $tag from $AxonHubRepo..."
    try {
      return Invoke-GitHubApi "/releases/tags/$tag"
    } catch {
      Write-Warn "GitHub API request failed ($($_.Exception.Message)); using direct download URLs"
      return New-ReleaseFromTag $tag
    }
  }

  Write-Info "Fetching releases from $AxonHubRepo (prereleases: $IncludePrerelease)..."
  $releases = @()
  try {
    for($page = 1; $page -le 10; $page++){
      $batch = Invoke-GitHubApi "/releases?per_page=100&page=$page"
      # Normalize before counting: PowerShell 5.1 returns a JSON array as a single object.
      $batch = @($batch)
      $releases += $batch
      if($batch.Count -lt 100){ break }
    }
  } catch {
    Write-Warn "GitHub API request failed ($($_.Exception.Message)); falling back to the release feed"
    Write-Warn 'Set GITHUB_TOKEN to avoid the API rate limit'
    try {
      $releases = Get-ReleasesFromFeed
    } catch {
      throw "Could not list releases of ${AxonHubRepo}: $($_.Exception.Message)"
    }
  }

  $best = Select-LatestRelease $releases $IncludePrerelease
  if($null -eq $best){ throw "No matching release found in $AxonHubRepo" }
  return $best
}

function Get-ReleaseArchive($Release){
  $platform = Get-Platform
  $asset = @($Release.assets) | Where-Object { $_.name -like "*_$platform.zip" } | Select-Object -First 1
  if(-not $asset){ throw "Release $($Release.tag_name) has no $platform archive" }
  return $asset
}

function Confirm-Checksum($Release, $Asset, [string]$file){
  $expected = ''
  if("$($Asset.digest)" -match '^sha256:([0-9a-fA-F]{64})$'){
    $expected = $Matches[1]
  } else {
    $sums = @($Release.assets) | Where-Object { $_.name -eq 'checksums.txt' } | Select-Object -First 1
    if($sums){
      $text = (Invoke-WebRequest -Uri $sums.browser_download_url -UseBasicParsing).Content
      if($text -is [byte[]]){ $text = [Text.Encoding]::UTF8.GetString($text) }
      foreach($line in ($text -split "`r?`n")){
        if($line -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($Asset.name))$"){ $expected = $Matches[1] }
      }
    }
  }
  if(-not $expected){
    Write-Warn "No checksum published for $($Asset.name); skipping verification"
    return
  }
  $actual = Get-Sha256 $file
  if($actual -ne $expected.ToUpperInvariant()){
    throw "Checksum mismatch for $($Asset.name): expected $expected, got $actual"
  }
  Write-Info 'Checksum verified'
}

# Copies the managed scripts into $BaseDir, skipping files that are already identical.
function Sync-ManagedFiles([string]$sourceDir){
  if(Test-SamePath $sourceDir $BaseDir){ return }
  foreach($name in $ManagedFiles){
    $src = Join-Path $sourceDir $name
    if(-not (Test-Path -LiteralPath $src -PathType Leaf)){ continue }
    $dst = Join-Path $BaseDir $name
    if((Test-Path -LiteralPath $dst -PathType Leaf) -and
      (Get-Sha256 $src) -eq (Get-Sha256 $dst)){ continue }
    Write-Dbg "Updating $name"
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
}

# Downloads the release archive and swaps in its binary and scripts. AxonHub is stopped
# first because Windows locks the executable of a running process. The previous binary
# is kept as axonhub.exe.old so Start-AxonHubOrRollback can restore it.
function Install-AxonHubRelease($Release){
  $asset = Get-ReleaseArchive $Release
  $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("axonhub-" + [guid]::NewGuid().ToString('N'))
  Ensure-Dir $tempDir
  try {
    $zip = Join-Path $tempDir $asset.name
    Write-Info "Downloading $($asset.browser_download_url)"
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing -Headers @{ 'User-Agent' = 'axonhub-windows-scripts' }
    Confirm-Checksum $Release $asset $zip

    $extractDir = Join-Path $tempDir 'extract'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $extractDir)
    $newBinary = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter 'axonhub.exe' -File | Select-Object -First 1
    if(-not $newBinary){ throw 'axonhub.exe not found in the release archive' }
    $newVersion = Get-BinaryVersion $newBinary.FullName
    if(-not $newVersion){ throw 'The downloaded axonhub.exe does not run on this machine' }

    Ensure-Dir $BaseDir
    Ensure-Dir $LogDir
    Stop-AxonHub

    Remove-Item -LiteralPath $BackupBinaryPath -Force -ErrorAction SilentlyContinue
    if(Test-Path -LiteralPath $BinaryPath -PathType Leaf){
      Move-Item -LiteralPath $BinaryPath -Destination $BackupBinaryPath
    }
    try {
      Copy-Item -LiteralPath $newBinary.FullName -Destination $BinaryPath -Force
    } catch {
      if(Test-Path -LiteralPath $BackupBinaryPath -PathType Leaf){
        Copy-Item -LiteralPath $BackupBinaryPath -Destination $BinaryPath -Force
      }
      throw "Could not replace ${BinaryPath}: $($_.Exception.Message)"
    }

    $installed = Get-BinaryVersion $BinaryPath
    if($installed -ne $newVersion){
      throw "Installed binary reports '$installed', expected '$newVersion'"
    }
    Write-Success "Installed AxonHub $installed"

    # Archives built before these scripts existed ship the upstream scripts, which talk to a
    # different repository. Keep the running scripts in that case instead of downgrading them.
    $scriptSource = $newBinary.DirectoryName
    if(-not (Test-Path -LiteralPath (Join-Path $scriptSource 'axonhub-common.ps1') -PathType Leaf)){
      Write-Dbg 'Release archive ships legacy scripts; keeping the current scripts'
      $scriptSource = $PSScriptRoot
    }
    Sync-ManagedFiles $scriptSource
  } finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# Starts the freshly installed binary; if it fails, restores axonhub.exe.old and starts that.
function Start-AxonHubOrRollback {
  try {
    Start-AxonHub
  } catch {
    $reason = $_.Exception.Message
    if(-not (Test-Path -LiteralPath $BackupBinaryPath -PathType Leaf)){ throw }
    Write-Err "New version failed to start: $reason"
    Write-Warn 'Rolling back to the previous binary...'
    Stop-AxonHub
    Copy-Item -LiteralPath $BackupBinaryPath -Destination $BinaryPath -Force
    Start-AxonHub
    throw "Upgrade rolled back to $(Get-BinaryVersion $BinaryPath): $reason"
  }
}
