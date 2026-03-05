param(
  [string]$Branch = "",
  [switch]$SkipPythonDeps
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$AppRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = if ($env:SMART_CONTROLLER_DATA_DIR) { $env:SMART_CONTROLLER_DATA_DIR } else { Join-Path $AppRoot "data" }
$DayLocal = Get-Date -Format "yyyyMMdd"
$SessionStamp = Get-Date -Format "yyyyMMddTHHmmssK"
$SessionId = "win-updater-$SessionStamp-$PID"
$SessionDir = Join-Path $DataDir "logs\updater\sessions\$SessionId"
$ActivityLog = Join-Path $SessionDir "activity-$DayLocal.log"
$ErrorLog = Join-Path $SessionDir "errors-$DayLocal.log"

New-Item -ItemType Directory -Force -Path $SessionDir | Out-Null
New-Item -ItemType File -Force -Path $ActivityLog | Out-Null
New-Item -ItemType File -Force -Path $ErrorLog | Out-Null

function Write-Activity {
  param([string]$Message)
  $line = "[8bb-win-updater] $Message"
  $line | Tee-Object -FilePath $ActivityLog -Append
}

function Write-ErrorLog {
  param([string]$Message)
  $line = "[8bb-win-updater] ERROR: $Message"
  $line | Tee-Object -FilePath $ActivityLog -Append
  $line | Out-File -FilePath $ErrorLog -Append -Encoding utf8
}

function Load-EnvFile {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    return
  }
  Write-Activity "Loading env from $Path"
  foreach ($raw in Get-Content -LiteralPath $Path) {
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $line = $raw.Trim()
    if ($line.StartsWith("#")) { continue }
    $idx = $line.IndexOf("=")
    if ($idx -lt 1) { continue }
    $key = $line.Substring(0, $idx).Trim()
    $value = $line.Substring($idx + 1).Trim()
    if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    } elseif ($value.StartsWith("'") -and $value.EndsWith("'") -and $value.Length -ge 2) {
      $value = $value.Substring(1, $value.Length - 2)
    } else {
      $hash = $value.IndexOf("#")
      if ($hash -ge 0) {
        $value = $value.Substring(0, $hash).Trim()
      }
    }
    if ($key) {
      [System.Environment]::SetEnvironmentVariable($key, $value, "Process")
    }
  }
}

function Resolve-RepoSlug {
  $repo = $env:GITHUB_REPO
  $repoName = if ($env:GITHUB_REPO_NAME) { $env:GITHUB_REPO_NAME } else { "8bbSmartController" }
  if ([string]::IsNullOrWhiteSpace($repo)) {
    return "imstuee76/8bbSmartController"
  }
  if ($repo.Contains("/")) {
    return $repo
  }
  return "$repo/$repoName"
}

function Sync-Path {
  param(
    [string]$SourceRoot,
    [string]$RelativePath
  )
  $src = Join-Path $SourceRoot $RelativePath
  $dst = Join-Path $AppRoot $RelativePath
  if (-not (Test-Path -LiteralPath $src)) {
    Write-Activity "Skip missing path in update bundle: $RelativePath"
    return
  }
  if (Test-Path -LiteralPath $src -PathType Container) {
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    $cmd = @("robocopy", $src, $dst, "/MIR", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    Write-Activity ('$ ' + ($cmd -join ' '))
    & robocopy $src $dst /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) {
      throw "robocopy failed for $RelativePath (exit=$LASTEXITCODE)"
    }
  } else {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
    Write-Activity ('$ Copy-Item ' + $src + ' -> ' + $dst)
    Copy-Item -LiteralPath $src -Destination $dst -Force
  }
}

function Resolve-Python {
  $py = Get-Command python -ErrorAction SilentlyContinue
  if ($py) {
    return $py.Path
  }
  $launcher = Get-Command py -ErrorAction SilentlyContinue
  if ($launcher) {
    return "py -3"
  }
  return ""
}

$envFile = if (Test-Path -LiteralPath (Join-Path $DataDir ".env")) {
  Join-Path $DataDir ".env"
} elseif (Test-Path -LiteralPath (Join-Path $AppRoot ".env")) {
  Join-Path $AppRoot ".env"
} else {
  ""
}
if ($envFile) {
  Load-EnvFile -Path $envFile
}

$RepoSlug = Resolve-RepoSlug
$BranchName = if ($Branch) { $Branch } elseif ($env:GIT_BRANCH) { $env:GIT_BRANCH } else { "main" }
$ApiUrl = "https://api.github.com/repos/$RepoSlug/tarball/$BranchName"

$tmpRoot = Join-Path $env:TEMP ("8bb-win-updater-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null
$archive = Join-Path $tmpRoot "repo.tar.gz"
$extract = Join-Path $tmpRoot "extract"
New-Item -ItemType Directory -Force -Path $extract | Out-Null

try {
  Write-Activity "Session: $SessionId"
  Write-Activity "App root: $AppRoot"
  Write-Activity "Data dir: $DataDir"
  Write-Activity "Activity log: $ActivityLog"
  Write-Activity "Error log: $ErrorLog"
  Write-Activity "Controller runtime update source: $RepoSlug ($BranchName)"

  $headers = @{ Accept = "application/vnd.github+json" }
  if ($env:GITHUB_TOKEN) {
    $headers.Authorization = "Bearer $($env:GITHUB_TOKEN)"
  }
  Write-Activity ('$ Invoke-WebRequest ' + $ApiUrl + ' -> ' + $archive)
  Invoke-WebRequest -Uri $ApiUrl -Headers $headers -OutFile $archive

  Write-Activity ('$ tar -xzf ' + $archive + ' -C ' + $extract)
  tar -xzf $archive -C $extract
  if ($LASTEXITCODE -ne 0) {
    throw "tar extraction failed with exit code $LASTEXITCODE"
  }

  $srcRoot = Get-ChildItem -LiteralPath $extract -Directory | Select-Object -First 1
  if (-not $srcRoot) {
    throw "Could not locate extracted source folder."
  }

  $syncPaths = @(
    "controller-app",
    "flasher-web",
    "esp32-firmware",
    "shared",
    "run.py",
    "run.cmd",
    "windows-controller-updater.ps1",
    "windows-controller-updater.cmd",
    ".env.example",
    "README.md"
  )

  foreach ($rel in $syncPaths) {
    Sync-Path -SourceRoot $srcRoot.FullName -RelativePath $rel
  }

  if (-not $SkipPythonDeps) {
    $py = Resolve-Python
    $req = Join-Path $AppRoot "flasher-web\requirements.txt"
    if ($py -and (Test-Path -LiteralPath $req)) {
      if ($py -eq "py -3") {
        Write-Activity ('$ py -3 -m pip install --user --upgrade -r ' + $req)
        py -3 -m pip install --user --upgrade -r $req
      } else {
        Write-Activity ('$ ' + $py + ' -m pip install --user --upgrade -r ' + $req)
        & $py -m pip install --user --upgrade -r $req
      }
    } else {
      Write-Activity "Python or requirements not found; skipping pip install."
    }
  }

  Write-Activity "Update complete. Preserved: $DataDir and .env files."
  Write-Activity "Updater errors (if any): $ErrorLog"
  exit 0
}
catch {
  Write-ErrorLog $_.Exception.Message
  exit 1
}
finally {
  if (Test-Path -LiteralPath $tmpRoot) {
    Remove-Item -LiteralPath $tmpRoot -Force -Recurse -ErrorAction SilentlyContinue
  }
}
