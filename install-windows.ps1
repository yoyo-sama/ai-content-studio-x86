#Requires -Version 5.1
<#
install-windows.ps1 - idempotent install/update of the AI Content Studio stack
(web server, portable ComfyUI, Ollama) on a Windows 10/11 x86_64 machine with a
dedicated Nvidia GPU. 100% native, no Docker.

Cote Linux : install-ubuntu.sh / install-omarchy.sh (variante Docker).

Targets Windows PowerShell 5.1 (the one shipped with Windows) - no PS7 syntax.
Re-runnable at will: nothing is downloaded or created again when already present
and valid. No non-critical failure stops the script; everything is reported in
the final summary.

Usage :
  powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
  $env:HF_TOKEN = "hf_xxx"; powershell -ExecutionPolicy Bypass -File .\install-windows.ps1
#>

$RepoRoot     = $PSScriptRoot
$Portable     = Join-Path $RepoRoot 'ComfyUI_windows_portable'
$RunBat       = Join-Path $Portable 'run_nvidia_gpu.bat'
$PythonEmbed  = Join-Path $Portable 'python_embeded\python.exe'
$ModelsDir    = Join-Path $Portable 'ComfyUI\models'
$SevenZip     = Join-Path $RepoRoot '7zr.exe'
$Archive      = Join-Path $RepoRoot 'ComfyUI_windows_portable_nvidia.7z'
$ServeScript  = Join-Path $RepoRoot 'scripts\serve-windows.ps1'
$ModelsFile   = Join-Path $RepoRoot 'scripts\models.txt'

$SevenZipUrl  = 'https://www.7-zip.org/a/7zr.exe'
$PortableUrl  = 'https://github.com/comfyanonymous/ComfyUI/releases/latest/download/ComfyUI_windows_portable_nvidia.7z'
$OllamaSetup  = 'https://ollama.com/download/OllamaSetup.exe'

# Statuses reported in the final summary (7/7).
$ComfyStatus   = 'inconnu'
$KitchenStatus = 'inconnu'
$OllamaStatus  = 'inconnu'
$GemmaStatus   = 'inconnu'
$WebStatus     = 'inconnu'
$Downloaded    = @()
$Skipped       = @()
$Failed        = @()
$Manual        = @()

function section($text) { Write-Host ''; Write-Host "=== $text ===" }
function warn($text)    { Write-Host "AVERTISSEMENT: $text" -ForegroundColor Yellow }

# Every HTTP request goes through curl.exe: one single mechanism, identical to the
# Linux scripts, and without the TLS/IE-engine surprises of Invoke-WebRequest on 5.1.
function Test-Http($url) {
    & curl.exe -s -f -o NUL --max-time 5 $url | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-HttpCode($url) {
    return (& curl.exe -s -o NUL --max-time 5 -w '%{http_code}' $url)
}

# ---------------------------------------------------------------------------
section "1/7 Verifications d'environnement (Windows x86_64 + GPU Nvidia)"
# ---------------------------------------------------------------------------
Write-Host "Windows : $([System.Environment]::OSVersion.VersionString)"
Write-Host "PowerShell : $($PSVersionTable.PSVersion)"
Write-Host "Repertoire du depot : $RepoRoot"

if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1 | ForEach-Object { Write-Host "GPU : $_" }
    if ($LASTEXITCODE -ne 0) {
        warn "'nvidia-smi' is present but failing - the Nvidia driver is probably not loaded properly. Continuing (graceful degradation)."
    }
} else {
    warn "'nvidia-smi' not found - the proprietary Nvidia driver is missing or out of PATH."
    Write-Host "  Install the GeForce/Studio driver from https://www.nvidia.com/download/index.aspx then reboot."
    Write-Host "  Le script continue quand meme (degradation propre) - ComfyUI tournera en CPU ou echouera au demarrage."
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: 'curl.exe' not found. It ships natively with Windows 10 1803+ and Windows 11." -ForegroundColor Red
    Write-Host "        Every download in this script depends on it. Update Windows then run this again." -ForegroundColor Red
    exit 1
}
Write-Host 'OK: curl.exe disponible.'

# ---------------------------------------------------------------------------
section '2/7 ComfyUI portable (Windows, build Nvidia)'
# ---------------------------------------------------------------------------
if (Test-Path $RunBat) {
    Write-Host "SKIP (already installed, nothing to download again): $Portable"
    $ComfyStatus = 'already present (not downloaded again)'
} else {
    if (Test-Path $SevenZip) {
        Write-Host "SKIP (already present): $SevenZip"
    } else {
        Write-Host "Telechargement de 7zr.exe (extracteur .7z, ~600 Ko) depuis $SevenZipUrl"
        & curl.exe -L --fail -o $SevenZip $SevenZipUrl
        # curl leaves a file behind (often empty) even when --fail triggers: without this
        # cleanup, the next run would see an existing 7zr.exe and skip it forever on an
        # unusable binary.
        if ($LASTEXITCODE -ne 0) {
            Remove-Item $SevenZip -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $SevenZip)) {
        warn "could not obtain 7zr.exe - the ComfyUI .7z archive cannot be extracted (Expand-Archive does not handle the .7z format)."
        $ComfyStatus = 'failed (7zr.exe unavailable)'
    } else {
        Write-Host ''
        Write-Host 'Telechargement de ComfyUI portable (~2,0 Go - cela peut prendre du temps).'
        Write-Host 'A network drop is not a problem: run this script again, the download resumes where it stopped (curl -C -).'
        & curl.exe -L -C - --fail -o $Archive $PortableUrl

        if ($LASTEXITCODE -ne 0) {
            warn "portable ComfyUI download failed (curl code $LASTEXITCODE). Run the script again to resume the download."
            $ComfyStatus = 'failed (download)'
        } else {
            Write-Host ''
            Write-Host "Extracting the archive into $RepoRoot ..."
            & $SevenZip x $Archive "-o$RepoRoot" -y
            if ((Test-Path $RunBat)) {
                Write-Host 'OK: ComfyUI portable extrait.'
                $ComfyStatus = 'installe'
            } else {
                warn "extraction finished but '$RunBat' is missing - incomplete or corrupt archive. Delete '$Archive' and run the script again."
                $ComfyStatus = 'failed (extraction)'
            }
        }
    }
}

# ---------------------------------------------------------------------------
section '3/7 comfy_kitchen (acceleration optionnelle)'
# ---------------------------------------------------------------------------
if (-not (Test-Path $PythonEmbed)) {
    warn "python_embeded not found ($PythonEmbed) - comfy_kitchen installation skipped."
    $KitchenStatus = 'ignore (ComfyUI portable absent)'
} else {
    Write-Host 'Installing comfy_kitchen into ComfyUI embedded Python (prebuilt win_amd64 wheel, no compilation needed).'
    & $PythonEmbed -m pip install comfy_kitchen
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'OK: comfy_kitchen disponible.'
        $KitchenStatus = 'installe'
    } else {
        warn "acceleration optionnelle non installee (pip code $LASTEXITCODE - reseau ou proxy ?)."
        Write-Host "  This is NOT a prerequisite: ComfyUI core node ModelAttentionBackend falls back"
        Write-Host "  automatically to 'pytorch attention' when comfy_kitchen is missing (just a"
        Write-Host '  warning in the ComfyUI logs). Everything works, only a bit slower.'
        $KitchenStatus = 'non installe (optionnel, degradation auto vers pytorch attention)'
    }
}

# ---------------------------------------------------------------------------
section '4/7 Downloading models (scripts/models.txt)'
# ---------------------------------------------------------------------------
if (-not (Test-Path $ModelsFile)) {
    Write-Host 'scripts\models.txt not found - no model to download.'
} elseif (-not (Test-Path $Portable)) {
    warn 'portable ComfyUI missing - model downloads postponed. Run the script again once ComfyUI is installed.'
} else {
    foreach ($rawLine in (Get-Content $ModelsFile)) {
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        $parts = $line.Split('|')
        if ($parts.Count -lt 4) { continue }

        $folder = $parts[0].Trim().Replace('/', '\')
        $file = $parts[1].Trim()
        $size   = $parts[2].Trim()
        $url     = $parts[3].Trim()

        $targetDir  = Join-Path $ModelsDir $folder
        $targetPath = Join-Path $targetDir $file

        if ($url -eq '' -or $url -eq 'NON_TROUVE') {
            $Manual += $targetPath
            continue
        }

        $expected = $size -as [long]
        if ($null -eq $expected) { $expected = 0 }

        if ((Test-Path $targetPath) -and ($expected -gt 0)) {
            $actual = (Get-Item $targetPath).Length
            $diff = [Math]::Abs($actual - $expected)
            $tolerance = [Math]::Max([long]($expected / 100), 1)
            if ($diff -le $tolerance) {
                Write-Host "SKIP (already present, size matches): $targetPath"
                $Skipped += $targetPath
                continue
            }
        }

        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Write-Host ''
        Write-Host "Downloading: $file -> $targetPath"

        # Some Hugging Face repositories (e.g. Lightricks/LTX-2.5) are "gated": an
        # anonymous download fails with 401 until the terms have been accepted on
        # huggingface.co with an account and a token is provided.
        # HF_TOKEN is used when set; otherwise the failure is reported cleanly in the
        # summary without blocking the other downloads.
        $curlArgs = @('-L', '-C', '-', '--fail', '-o', $targetPath, $url)
        if ($env:HF_TOKEN -and ($url -like '*huggingface.co*')) {
            $curlArgs = @('-L', '-C', '-', '--fail', '-H', "Authorization: Bearer $($env:HF_TOKEN)", '-o', $targetPath, $url)
        }

        & curl.exe $curlArgs
        if ($LASTEXITCODE -eq 0) {
            $Downloaded += $targetPath
        } else {
            warn "download failed for '$file' (curl code $LASTEXITCODE)"
            $Failed += "$targetPath ($url)"
        }
    }
}

# ---------------------------------------------------------------------------
section '5/7 Ollama'
# ---------------------------------------------------------------------------
# Ollama may ALREADY be installed on this machine: never assume it is absent.
# (a) the service already answers -> touch nothing
# (b) installed but stopped   -> try to start it
# (c) genuinely missing       -> guide the user, never install on their behalf

# Binary path resolved once: used both by (b) and by the model pull further down.
$OllamaCli = ''
$cliCmd = Get-Command ollama -ErrorAction SilentlyContinue
if ($cliCmd) {
    $OllamaCli = $cliCmd.Source
} else {
    $cliPath = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    if (Test-Path $cliPath) { $OllamaCli = $cliPath }
}
$OllamaTray = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama app.exe'

$OllamaUp = $false

# (a) --------------------------------------------------------------------
if (Test-Http 'http://localhost:11434/api/version') {
    Write-Host 'OK: Ollama already answers on :11434 - reusing it, nothing to do.'
    $OllamaStatus = 'already running'
    $OllamaUp = $true
} else {
    # (b) ----------------------------------------------------------------
    $started = $false
    if (Test-Path $OllamaTray) {
        Write-Host "Ollama installe mais eteint - demarrage de l'application : $OllamaTray"
        Start-Process -FilePath $OllamaTray
        $started = $true
    } elseif ($OllamaCli -ne '') {
        Write-Host "Ollama installe mais eteint - demarrage du serveur : $OllamaCli serve"
        Start-Process -FilePath $OllamaCli -ArgumentList 'serve' -WindowStyle Minimized
        $started = $true
    }

    if ($started) {
        Write-Host 'Waiting for the service to answer (5 attempts, 2 s apart)...'
        for ($i = 1; $i -le 5; $i++) {
            Start-Sleep -Seconds 2
            if (Test-Http 'http://localhost:11434/api/version') {
                $OllamaUp = $true
                break
            }
            Write-Host "  attempt $i/5 - no answer on :11434 yet"
        }
        if ($OllamaUp) {
            Write-Host 'OK: Ollama started and answers on :11434.'
            $OllamaStatus = 'started by this script'
        } else {
            warn 'Ollama was launched but still does not answer on :11434 after 5 attempts.'
            Write-Host '  Check the Ollama icon in the notification area, then run this script again.'
            $OllamaStatus = 'launched but no answer on :11434'
        }
    } else {
        # (c) ------------------------------------------------------------
        warn 'Ollama not found on this machine (neither running nor installed).'
        Write-Host "  Telechargez et lancez l'installeur officiel : $OllamaSetup"
        Write-Host '  Then run this script again: it will detect Ollama and carry on.'
        Write-Host "  (this script deliberately installs no system component on your behalf)"
        $OllamaStatus = 'absent (installation manuelle requise)'
    }
}

# gemma4:e4b model - only when the service answers.
if (-not $OllamaUp) {
    $GemmaStatus = 'not checked (Ollama unavailable)'
} else {
    $tags = & curl.exe -s --max-time 10 'http://localhost:11434/api/tags'
    if ("$tags" -like '*"gemma4:e4b"*') {
        Write-Host 'OK: gemma4:e4b already present - no download needed.'
        $GemmaStatus = 'present'
    } elseif ($OllamaCli -eq '') {
        warn "the Ollama service answers but the 'ollama' binary is missing - cannot run the pull automatically."
        Write-Host '  Lancez manuellement : ollama pull gemma4:e4b'
        $GemmaStatus = 'absent (pull manuel requis)'
    } else {
        Write-Host 'gemma4:e4b absent - telechargement en cours (peut prendre plusieurs minutes)...'
        & $OllamaCli pull gemma4:e4b
        if ($LASTEXITCODE -eq 0) {
            $GemmaStatus = 'downloaded'
        } else {
            warn "gemma4:e4b pull failed (code $LASTEXITCODE)."
            $GemmaStatus = 'failed'
        }
    }
}

# ---------------------------------------------------------------------------
section '6/7 Starting the services'
# ---------------------------------------------------------------------------
Write-Host '--- ComfyUI (:8188) ---'
if (Test-Http 'http://localhost:8188/system_stats') {
    Write-Host 'ComfyUI already answers on :8188 - reusing it, not restarting.'
} elseif (-not (Test-Path $RunBat)) {
    warn "'$RunBat' not found - ComfyUI cannot be started (see section 2/7)."
} else {
    Write-Host "Demarrage de ComfyUI : $RunBat"
    Start-Process -FilePath $RunBat -WorkingDirectory $Portable
    Write-Host '  (ComfyUI listens on 127.0.0.1:8188; the first start can take a minute)'
}

Write-Host ''
Write-Host '--- Serveur web + proxy (:8090) ---'
if (Test-Http 'http://localhost:8090/') {
    Write-Host 'The web server already answers on :8090 - reusing it, not restarting.'
    $WebStatus = 'already running'
} elseif (-not (Test-Path $ServeScript)) {
    warn "'$ServeScript' not found - the web server cannot be started."
    $WebStatus = 'failed (scripts\serve-windows.ps1 missing)'
} else {
    Write-Host "Demarrage du serveur web : $ServeScript"
    Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',"$RepoRoot\scripts\serve-windows.ps1",'-Root',"$RepoRoot",'-Port','8090' -WindowStyle Minimized
    $WebStatus = 'demarre'
}

# ---------------------------------------------------------------------------
section '7/7 Recapitulatif final'
# ---------------------------------------------------------------------------
Write-Host 'Composants :'
Write-Host "  - ComfyUI portable : $ComfyStatus"
Write-Host "  - comfy_kitchen    : $KitchenStatus"
Write-Host "  - Ollama           : $OllamaStatus"
Write-Host "  - gemma4:e4b       : $GemmaStatus"
Write-Host "  - Serveur web      : $WebStatus"
Write-Host ''
Write-Host 'Modeles ComfyUI (scripts\models.txt) :'
Write-Host "  - already present (not downloaded again) : $($Skipped.Count)"
Write-Host "  - downloaded this run                    : $($Downloaded.Count)"
if ($Failed.Count -gt 0) {
    Write-Host '  - echecs de telechargement :'
    foreach ($f in $Failed) { Write-Host "      $f" }
    Write-Host "    (if the failure is a Lightricks/LTX-2.5 file: that Hugging Face repository is"
    Write-Host "    'gated' - accept its terms on the HF page with your account, then run"
    Write-Host '    ce script apres avoir defini $env:HF_TOKEN = "<votre_jeton>")'
}
if ($Manual.Count -gt 0) {
    Write-Host '  - a telecharger manuellement (URL NON_TROUVE, voir README) :'
    foreach ($m in $Manual) { Write-Host "      $m" }
}
Write-Host ''
Write-Host 'Health-checks finaux :'
foreach ($port in @(8188, 11434, 8090)) {
    $code = Get-HttpCode "http://localhost:$port/"
    Write-Host "  - :$port -> HTTP $code"
}
Write-Host ''
Write-Host "Interface : http://localhost:8090/"
Write-Host 'This script can be re-run at will: nothing already present and valid is downloaded again.'
