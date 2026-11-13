# claude-code-android: installs Claude Code on an Android phone connected by USB.
# Windows entry point. Double-click install.bat, or run:
#   powershell -ExecutionPolicy Bypass -File install.ps1
# The real work happens in phone/setup.sh, which this script copies to the phone
# and runs there. This script only finds adb, waits for the phone, fetches the
# Termux app, and passes on the phone's questions.
# Keep its behaviour and wording in step with install.sh.
param([switch]$Uninstall)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$PhoneDir = '/data/local/tmp/claude-code-android'
$Cache = Join-Path $Root '.cache'
New-Item -ItemType Directory -Force $Cache, (Join-Path $Root 'logs') | Out-Null
$LogName = 'logs\install-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss')
$Log = Join-Path $Root $LogName

function Say([string]$Text = '') {
    Write-Host $Text
    Add-Content -LiteralPath $Log -Value $Text
}

function Quit([string]$Text, [int]$Code = 1) {
    Say ''
    Say $Text
    Say "Log: $LogName (in this folder)"
    exit $Code
}

# Ask a question; the answer is logged. An empty answer is what Enter or a
# closed input gives.
function Ask([string]$Question) {
    $answer = Read-Host $Question
    Add-Content -LiteralPath $Log -Value "$Question -> $answer"
    return "$answer"
}

function Confirm-Yes([string]$Question) { return (Ask "$Question [y/N]") -match '^(y|yes)$' }

function Read-Versions {
    $values = @{}
    foreach ($line in Get-Content -LiteralPath (Join-Path $Root 'versions.env')) {
        if ($line -match '^([A-Z0-9_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
    }
    return $values
}

function Test-Hash([string]$Path, [string]$Expected) {
    return (Test-Path $Path) -and ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Expected)
}

# Use adb if the laptop already has it; otherwise fetch Google's copy into .tools.
function Find-Adb {
    if ($env:CCA_ADB) { Say '(test setting CCA_ADB is in use)'; return $env:CCA_ADB }
    $onPath = Get-Command adb -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $local = Join-Path $Root '.tools\platform-tools\adb.exe'
    if (Test-Path $local) { return $local }

    Say 'This laptop does not have adb, the Android tool that talks to the phone.'
    Say 'The installer can download it from Google (about 10 MB) into this folder.'
    Say 'Nothing is installed on Windows itself. Google''s terms: https://developer.android.com/studio/terms'
    if (-not (Confirm-Yes 'Download adb from Google?')) { Quit 'Cancelled. Nothing was changed.' }
    $tools = Join-Path $Root '.tools'
    New-Item -ItemType Directory -Force $tools | Out-Null
    $zip = Join-Path $tools 'platform-tools.zip'
    try {
        Invoke-WebRequest -UseBasicParsing -OutFile $zip `
            -Uri "https://dl.google.com/android/repository/platform-tools_r$($Versions.ADB_VERSION)-win.zip"
    } catch {
        Quit 'Could not download adb. Check the laptop''s internet connection and run the installer again.'
    }
    if (-not (Test-Hash $zip $Versions.ADB_SHA256_WIN)) {
        Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
        Quit 'The downloaded adb file is not the one this installer expects, so it was not used. Run the installer again; if it keeps happening, report it.'
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $tools -Force
    Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue
    if (-not (Test-Path $local)) { Quit 'The adb download did not unpack correctly. Run the installer again.' }
    return $local
}

# Run adb and return what it printed, dropping its progress and error chatter.
# adb gets no input, so it cannot swallow answers typed for this script.
# (Windows PowerShell turns a program's error output into script errors unless
# errors are set to Continue while it runs.)
function Invoke-Adb {
    $ErrorActionPreference = 'Continue'
    $out = $null | & $Adb @args 2>$null
    return , @($out)
}

# Returns a list of @{ Serial; State } for everything adb can see. Device lines
# are "serial<TAB>state"; adb's own status lines have no tab.
function Get-Devices {
    $found = @()
    foreach ($line in (Invoke-Adb devices)) {
        if ($line -match "^([^\t]+)\t(.+)$") {
            $serial = $Matches[1]
            $state = $Matches[2].Trim()
            if ($serial -notmatch '^[A-Za-z0-9._:-]+$') { Quit 'A connected device reports a name this installer does not accept. Unplug other devices and run it again.' }
            $found += @{ Serial = $serial; State = $state }
        }
    }
    return , $found
}

# Serial numbers identify a phone, so only their last four characters are shown.
function Hide-Serial([string]$Serial) {
    if ($Serial.Length -le 4) { return $Serial }
    return '...' + $Serial.Substring($Serial.Length - 4)
}

# Wait until exactly one phone is connected and has allowed this laptop.
function Wait-Phone {
    $shown = ''
    $waited = 0
    $asked = 0
    while ($true) {
        $devices = Get-Devices
        $ready = @($devices | Where-Object { $_.State -eq 'device' })
        if ($ready.Count -eq 1 -and $devices.Count -eq 1) { return $ready[0].Serial }

        if ($ready.Count -ge 1 -and $devices.Count -gt 1) {
            if ($asked -ge 5) { Quit 'No phone was chosen. Unplug the other devices and run the installer again.' }
            $asked++
            Say ''
            Say 'More than one Android device is connected:'
            for ($i = 0; $i -lt $ready.Count; $i++) {
                $model = (Invoke-Adb -s $ready[$i].Serial shell getprop ro.product.model) -join ''
                Say ("  {0}. {1} ({2})" -f ($i + 1), $model.Trim(), (Hide-Serial $ready[$i].Serial))
            }
            $pick = Ask 'Type the number of the phone to set up (or unplug the others and press Enter):'
            if ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $ready.Count) {
                return $ready[[int]$pick - 1].Serial
            }
            Start-Sleep -Seconds 2
            continue
        }

        $state = 'none'
        if ($devices.Count -ge 1) { $state = $devices[0].State }
        if ($state -eq 'none' -and $waited -ge 30) { $state = 'none-long' }
        if ($state -ne $shown) {
            $shown = $state
            Say ''
            switch ($state) {
                'none' {
                    Say 'Waiting for your phone...'
                    Say '  1. Plug the phone into this laptop with a USB cable (a data cable, not charge-only).'
                    Say '  2. On the phone: Settings > About phone > tap "Build number" 7 times.'
                    Say '  3. Settings > System > Developer options > switch on "USB debugging".'
                    Say '  Steps differ a little by brand: see docs\usb-debugging.md'
                    Say '  (Press Ctrl+C to cancel. Nothing has been changed yet.)'
                }
                'none-long' {
                    Say 'Still no phone. Things to try:'
                    Say '  - Another cable or USB port. Many cables only charge.'
                    Say '  - On the phone, pull down the notifications and set USB to "File transfer".'
                    Say '  - Windows may need your phone maker''s USB driver:'
                    Say '    https://developer.android.com/studio/run/oem-usb'
                }
                'unauthorized' {
                    Say 'Phone found. Now unlock it and look for "Allow USB debugging?".'
                    Say '  Tick "Always allow from this computer" and tap Allow.'
                    Say '  No prompt? Unplug the cable and plug it back in.'
                }
                'authorizing' { Say 'Waiting for you to tap Allow on the phone...' }
                'offline' { Say 'The phone is connected but not answering. Unplug the cable and plug it back in.' }
                default { Say 'The phone is in a maintenance mode. Restart it normally and wait for the home screen.' }
            }
        }
        Start-Sleep -Seconds 2
        $waited += 2
    }
}

# Copy the phone-side scripts over, with Unix line endings whatever git did.
function Push-Scripts {
    $stage = Join-Path $Cache 'push'
    New-Item -ItemType Directory -Force (Join-Path $stage 'phone') | Out-Null
    $utf8 = New-Object Text.UTF8Encoding $false
    Invoke-Adb -s $Serial shell "mkdir -p $PhoneDir/phone" | Out-Null
    foreach ($file in 'versions.env', 'phone/setup.sh', 'phone/termux-setup.sh', 'phone/guest-setup.sh') {
        $text = [IO.File]::ReadAllText((Join-Path $Root $file)) -replace "`r`n", "`n"
        [IO.File]::WriteAllText((Join-Path $stage $file), $text, $utf8)
        Invoke-Adb -s $Serial push (Join-Path $stage $file) "$PhoneDir/$file" | Out-Null
        if ($LASTEXITCODE -ne 0) { Quit 'Could not copy files to the phone. Unplug it, plug it back in, and run the installer again.' }
    }
}

# Run phone/setup.sh on the phone, showing and logging what it prints. Its last
# line is CCA_EXIT=<code>; if that never arrives, the connection was cut (255).
function Invoke-Phone([string[]]$Arguments) {
    $script:PhoneCode = 255
    $null | & $Adb -s $Serial shell "sh $PhoneDir/phone/setup.sh $($Arguments -join ' ')" | ForEach-Object {
        if ("$_" -match '^CCA_EXIT=(\d+)\s*$') { $script:PhoneCode = [int]$Matches[1] } else { Say "$_" }
    }
    return $script:PhoneCode
}

# Download the Termux app (once), check it is the exact file we expect, copy it over.
function Push-Termux {
    $apk = Join-Path $Cache "termux-$($Versions.TERMUX_VERSION).apk"
    if (-not (Test-Hash $apk $Versions.TERMUX_APK_SHA256)) {
        Say "Downloading Termux $($Versions.TERMUX_VERSION) (35 MB)..."
        $url = $Versions.TERMUX_APK_URL
        if ($env:CCA_TERMUX_APK_URL) { Say '(test setting CCA_TERMUX_APK_URL is in use)'; $url = $env:CCA_TERMUX_APK_URL }
        try {
            if (Test-Path $url) { Copy-Item -LiteralPath $url -Destination $apk -Force }
            else { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $apk }
        } catch {
            Quit 'Could not download Termux. Check the laptop''s internet connection and run the installer again.'
        }
        if (-not (Test-Hash $apk $Versions.TERMUX_APK_SHA256)) {
            Remove-Item -LiteralPath $apk -ErrorAction SilentlyContinue
            Quit 'The downloaded Termux file is not the one this installer expects, so it was not installed. Run the installer again; if it keeps happening, report it.'
        }
    }
    Invoke-Adb -s $Serial push $apk "$PhoneDir/termux.apk" | Out-Null
    if ($LASTEXITCODE -ne 0) { Quit 'Could not copy Termux to the phone. Unplug it, plug it back in, and run the installer again.' }
}

function Stop-AfterFailure([int]$Code) {
    $state = (Invoke-Adb -s $Serial get-state) -join ''
    if ($Code -eq 255 -or $state.Trim() -ne 'device') {
        Quit 'The connection to the phone was lost. Plug it back in and run this again; it continues where it stopped.' $Code
    }
    if ($Code -in 20, 21, 22, 23, 26) { Quit 'This phone cannot be set up, so nothing was changed on it.' $Code }
    if ($Uninstall) { Quit 'The removal did not finish. Fix the problem above and run the uninstaller again.' $Code }
    Quit 'The install did not finish. Fix the problem above and run the installer again; it continues where it stopped.' $Code
}

function Stop-Cancelled([string]$Text) {
    Invoke-Adb -s $Serial shell "rm -rf $PhoneDir" | Out-Null
    Quit $Text
}

# ---------------------------------------------------------------------------

Say 'claude-code-android: Claude Code on your Android phone'
Say '(unofficial community project, not made by Anthropic)'
Say ''

$Versions = Read-Versions
$Adb = Find-Adb
$Serial = Wait-Phone
Say ''
Say 'Phone connected.'
Push-Scripts

if ($Uninstall) {
    Say ''
    Say 'Removing Claude Code and its Linux guest from the phone...'
    $code = Invoke-Phone @('remove')
    if ($code -eq 13) {
        $answer = Ask 'To ALSO delete the Termux app with every file inside it, type REMOVE. Otherwise press Enter:'
        if ($answer -ceq 'REMOVE') { $code = Invoke-Phone @('remove', '--remove-termux') }
        else { Invoke-Adb -s $Serial shell "rm -rf $PhoneDir" | Out-Null; $code = 0 }
    }
    if ($code -ne 0) { Stop-AfterFailure $code }
    Quit 'Finished.' 0
}

$flags = @()
:preflight while ($true) {
    $code = Invoke-Phone (@('preflight') + $flags)
    switch ($code) {
        0 { break preflight }
        3 { Push-Termux; break preflight }
        10 {
            if (Confirm-Yes 'Add Claude Code to this Termux?') { $flags += '--use-existing-termux' }
            else { Stop-Cancelled 'Cancelled. Nothing was changed on the phone.' }
        }
        11 {
            if ((Ask 'Type REPLACE to delete the existing Termux and continue, or press Enter to cancel:') -ceq 'REPLACE') { $flags += '--replace-termux' }
            else { Stop-Cancelled 'Cancelled. Nothing was changed on the phone.' }
        }
        12 {
            if (Confirm-Yes 'Continue on mobile data?') { $flags += '--allow-mobile-data' }
            else { Stop-Cancelled 'Cancelled. Connect the phone to Wi-Fi and run the installer again.' }
        }
        default { Stop-AfterFailure $code }
    }
}

Say ''
Say 'Setting up the phone. This takes about 5 to 10 minutes. Keep the phone'
Say 'plugged in and unlocked.'
$code = Invoke-Phone (@('install') + $flags)
if ($code -ne 0) { Stop-AfterFailure $code }
Quit 'Finished.' 0
