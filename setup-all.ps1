# Kindle weather dashboard - automatic setup (PC side)
#
# What this script does:
#   1. Installs Git and GitHub CLI if missing (via winget)
#   2. Logs you in to GitHub (browser, once)
#   3. Creates the public repository, uploads the files, enables GitHub Pages
#      and starts the first build
#   4. Waits until the weather image is online
#   5. Copies the Kindle extension to your Kindle and writes your image URL into config.sh
#
# What it can NOT do: tap things on the Kindle itself.
# Afterwards: eject the Kindle, open KUAL > Wetter > "Testbild laden (einmalig)",
# then "Wetter-Dashboard starten".
#
# Usage:  double-click setup-all.bat
#         or: powershell -ExecutionPolicy Bypass -File .\setup-all.ps1 [-SkipGitHub] [-SkipKindle]

param(
    [string]$Repo = "kindle-wetter",
    [switch]$SkipGitHub,
    [switch]$SkipKindle
)

$ErrorActionPreference = "Continue"
$root = $PSScriptRoot

function Step($text)  { Write-Host ""; Write-Host "=== $text ===" -ForegroundColor Cyan }
function Info($text)  { Write-Host $text }
function Good($text)  { Write-Host $text -ForegroundColor Green }
function Warn($text)  { Write-Host $text -ForegroundColor Yellow }
function Fail($text)  { Write-Host $text -ForegroundColor Red; exit 1 }
function Ask($text)   { return ((Read-Host "$text (y/n)") -match '^(y|Y|j|J)') }
function Has($cmd)    { return [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}

function Ensure-Tool($cmd, $wingetId, $name) {
    if (Has $cmd) { return }
    Warn "$name is not installed."
    if (-not (Has "winget")) { Fail "Please install $name manually (winget not available), then run this script again." }
    if (-not (Ask "Install $name now with winget")) { Fail "$name is required." }
    winget install --id $wingetId -e --accept-package-agreements --accept-source-agreements
    Refresh-Path
    if (-not (Has $cmd)) { Fail "$name was installed but is not available yet. Close this window, open a new one and run the script again." }
}

$login = $null

# ------------------------------------------------------------------ 1. GitHub
if (-not $SkipGitHub) {
    Step "1/3  GitHub: repository, upload, Pages"

    Ensure-Tool "git" "Git.Git" "Git"
    Ensure-Tool "gh" "GitHub.cli" "GitHub CLI"

    gh auth status *> $null
    if ($LASTEXITCODE -ne 0) {
        Info "Log in to GitHub now. Follow the instructions (a browser window opens)."
        gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { Fail "GitHub login failed." }
    }
    gh auth setup-git *> $null

    $login = (gh api user --jq .login | Out-String).Trim()
    if (-not $login) { Fail "Could not read your GitHub user name." }
    Good "Logged in as $login"

    gh repo view "$login/$Repo" *> $null
    $exists = ($LASTEXITCODE -eq 0)

    Push-Location $root
    try {
        if (-not (Test-Path (Join-Path $root ".git"))) {
            git init *> $null
            git symbolic-ref HEAD refs/heads/main
        }

        $ignore = "www/`n*.log`n"
        [IO.File]::WriteAllText((Join-Path $root ".gitignore"), $ignore, (New-Object Text.UTF8Encoding($false)))

        git add -A
        git -c user.name="$login" -c user.email="$login@users.noreply.github.com" commit -m "Kindle weather dashboard" *> $null

        if ($exists) {
            if (-not (Ask "Repository $login/$Repo already exists. Replace its content with these files")) { Fail "Aborted." }
            git remote remove origin *> $null
            git remote add origin "https://github.com/$login/$Repo.git"
        } else {
            gh repo create "$login/$Repo" --public --description "Kindle weather dashboard" --source . --remote origin
            if ($LASTEXITCODE -ne 0) { Fail "Could not create the repository." }
        }

        git push -u origin main --force
        if ($LASTEXITCODE -ne 0) { Fail "Upload to GitHub failed." }
    } finally {
        Pop-Location
    }
    Good "Files uploaded."

    # Enable GitHub Pages with "GitHub Actions" as source
    gh api -X POST "repos/$login/$Repo/pages" -f build_type=workflow *> $null
    if ($LASTEXITCODE -ne 0) {
        gh api -X PUT "repos/$login/$Repo/pages" -f build_type=workflow *> $null
        if ($LASTEXITCODE -ne 0) {
            Warn "Could not enable Pages automatically."
            Warn "Do it by hand: GitHub > $Repo > Settings > Pages > Source: GitHub Actions."
            Read-Host "Press Enter when done"
        }
    }

    # Start the first build and wait for it
    Start-Sleep -Seconds 5
    gh workflow run dashboard.yml --repo "$login/$Repo" *> $null
    Start-Sleep -Seconds 10
    $runId = (gh run list --repo "$login/$Repo" --workflow dashboard.yml --limit 1 --json databaseId --jq ".[0].databaseId" | Out-String).Trim()
    if ($runId) {
        Info "Waiting for the first build (about 1 minute) ..."
        gh run watch $runId --repo "$login/$Repo" --exit-status *> $null
        if ($LASTEXITCODE -ne 0) {
            Warn "The build reported a problem. Check: https://github.com/$login/$Repo/actions"
        }
    }
} else {
    Step "1/3  GitHub (skipped)"
    $login = (Read-Host "Your GitHub user name").Trim()
    if (-not $login) { Fail "User name needed to build the image address." }
}

$url = "https://$($login.ToLower()).github.io/$Repo/dashboard.png"

# ------------------------------------------------------- 2. Wait for the image
Step "2/3  Waiting for the image to go online"
Info $url
$online = $false
for ($i = 0; $i -lt 30; $i++) {
    try {
        $r = Invoke-WebRequest -Uri ($url + "?t=" + [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -UseBasicParsing -TimeoutSec 20
        if ($r.StatusCode -eq 200 -and $r.RawContentLength -gt 1000) { $online = $true; break }
    } catch { }
    Start-Sleep -Seconds 10
}
if ($online) {
    Good "The weather image is online."
} else {
    Warn "The image is not reachable yet. This can take a few minutes after the first build."
    Warn "Open the address above in your browser to check. The Kindle setup continues anyway."
}

# ------------------------------------------------------------- 3. Kindle copy
if ($SkipKindle) {
    Step "3/3  Kindle (skipped)"
} else {
    Step "3/3  Kindle: install the extension"

    $drive = $null
    $found = Get-Volume | Where-Object { $_.FileSystemLabel -eq "Kindle" -and $_.DriveLetter }
    if ($found) {
        $drive = "$(@($found)[0].DriveLetter):\"
    } else {
        Warn "No drive named 'Kindle' found."
        $letter = Read-Host "Drive letter of the Kindle (e.g. E) or just Enter to skip"
        if ($letter) { $drive = ($letter.Trim().TrimEnd(':', '\') + ":\") }
    }

    if (-not $drive) {
        Warn "Kindle step skipped. Run the script again with the Kindle connected: setup-all.bat -SkipGitHub"
    } elseif (-not ((Test-Path (Join-Path $drive "documents")) -and (Test-Path (Join-Path $drive "system")))) {
        Fail "$drive does not look like a Kindle (folders 'documents' and 'system' missing)."
    } else {
        Good "Kindle found: $drive"

        $extRoot = Join-Path $drive "extensions"
        if (-not (Test-Path $extRoot)) {
            Warn "No 'extensions' folder on the Kindle - KUAL does not seem to be installed yet."
            Warn "I will create the folder anyway, but the menu only appears after KUAL is installed."
            New-Item -ItemType Directory -Path $extRoot | Out-Null
        }

        $src = Join-Path $root "kindle\extensions\wetter"
        $dst = Join-Path $extRoot "wetter"
        if (-not (Test-Path $src)) { Fail "Source folder not found: $src" }

        robocopy $src $dst /E /IS /IT /NFL /NDL /NJH /NJS | Out-Null
        if ($LASTEXITCODE -ge 8) { Fail "Copying failed (code $LASTEXITCODE). Is there enough free space on the Kindle?" }

        # Write the real image address into config.sh (Unix line endings!)
        $utf8 = New-Object Text.UTF8Encoding($false)
        $cfg = "#!/bin/sh`n"
        $cfg += "# Address of the weather image`n"
        $cfg += "IMAGE_URL=`"$url`"`n`n"
        $cfg += "# Seconds between two downloads (900 = 15 minutes)`n"
        $cfg += "INTERVALL=900`n"
        [IO.File]::WriteAllText((Join-Path $dst "config.sh"), $cfg, $utf8)

        # Make sure all scripts and menu files use Unix line endings
        Get-ChildItem -Path $dst -File | Where-Object { $_.Extension -in ".sh", ".json", ".xml" } | ForEach-Object {
            $text = [IO.File]::ReadAllText($_.FullName)
            [IO.File]::WriteAllText($_.FullName, ($text -replace "`r`n", "`n"), $utf8)
        }

        Good "Extension installed on the Kindle: $dst"
    }
}

# ---------------------------------------------------------------------- Done
Write-Host ""
Step "Done"
Info "Image address: $url"
Info ""
Info "On the Kindle:"
Info "  1. Eject the Kindle in Windows (system tray) and unplug it."
Info "  2. Open KUAL > Wetter > 'Testbild laden (einmalig)'. The dashboard should appear."
Info "  3. If it works: KUAL > Wetter > 'Wetter-Dashboard starten'."
Info "  4. Keep the Kindle on its charger. To stop: hold the power button for about 40 seconds."
Info ""
