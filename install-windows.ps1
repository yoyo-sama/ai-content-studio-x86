#Requires -Version 5.1
<#
install-windows.ps1 - installation/mise a jour idempotente de la stack AI Content
Studio (serveur web, ComfyUI portable, Ollama) sur un poste Windows 10/11 x86_64
avec GPU Nvidia dedie. 100% natif, sans Docker.

Cote Linux : install-ubuntu.sh / install-omarchy.sh (variante Docker).

Cible Windows PowerShell 5.1 (celui livre avec Windows) - pas de syntaxe PS7.
Relancable a volonte : rien n'est retelecharge ni recree si c'est deja present
et valide. Aucun echec non critique n'interrompt le script ; tout remonte dans
le recapitulatif final.

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

# Etats remontes dans le recapitulatif final (7/7).
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

# Toutes les requetes HTTP passent par curl.exe : mecanisme unique, identique aux
# scripts Linux, et sans les surprises de TLS/moteur IE d'Invoke-WebRequest en 5.1.
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
        warn "'nvidia-smi' present mais en erreur - driver Nvidia probablement mal charge. Le script continue (degradation propre)."
    }
} else {
    warn "'nvidia-smi' introuvable - driver Nvidia proprietaire absent ou hors PATH."
    Write-Host "  Installez le driver GeForce/Studio depuis https://www.nvidia.com/download/index.aspx puis redemarrez."
    Write-Host "  Le script continue quand meme (degradation propre) - ComfyUI tournera en CPU ou echouera au demarrage."
}

if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
    Write-Host "ERREUR: 'curl.exe' introuvable. Il est fourni nativement par Windows 10 1803+ et Windows 11." -ForegroundColor Red
    Write-Host "        Tous les telechargements de ce script en dependent. Mettez Windows a jour puis relancez." -ForegroundColor Red
    exit 1
}
Write-Host 'OK: curl.exe disponible.'

# ---------------------------------------------------------------------------
section '2/7 ComfyUI portable (Windows, build Nvidia)'
# ---------------------------------------------------------------------------
if (Test-Path $RunBat) {
    Write-Host "SKIP (deja installe, rien a retelecharger): $Portable"
    $ComfyStatus = 'deja present (non retelecharge)'
} else {
    if (Test-Path $SevenZip) {
        Write-Host "SKIP (deja present): $SevenZip"
    } else {
        Write-Host "Telechargement de 7zr.exe (extracteur .7z, ~600 Ko) depuis $SevenZipUrl"
        & curl.exe -L --fail -o $SevenZip $SevenZipUrl
        # curl laisse un fichier (souvent vide) meme quand --fail declenche : sans ce
        # menage, la relance suivante verrait un 7zr.exe present et passerait son tour
        # indefiniment sur un binaire inutilisable.
        if ($LASTEXITCODE -ne 0) {
            Remove-Item $SevenZip -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not (Test-Path $SevenZip)) {
        warn "impossible d'obtenir 7zr.exe - l'archive .7z de ComfyUI ne peut pas etre extraite (Expand-Archive ne gere pas le format .7z)."
        $ComfyStatus = 'echec (7zr.exe indisponible)'
    } else {
        Write-Host ''
        Write-Host 'Telechargement de ComfyUI portable (~2,0 Go - cela peut prendre du temps).'
        Write-Host 'Une coupure reseau n''est pas un probleme : relancez ce script, le telechargement reprend ou il s''est arrete (curl -C -).'
        & curl.exe -L -C - --fail -o $Archive $PortableUrl

        if ($LASTEXITCODE -ne 0) {
            warn "echec du telechargement de ComfyUI portable (curl code $LASTEXITCODE). Relancez le script pour reprendre le telechargement."
            $ComfyStatus = 'echec (telechargement)'
        } else {
            Write-Host ''
            Write-Host "Extraction de l'archive dans $RepoRoot ..."
            & $SevenZip x $Archive "-o$RepoRoot" -y
            if ((Test-Path $RunBat)) {
                Write-Host 'OK: ComfyUI portable extrait.'
                $ComfyStatus = 'installe'
            } else {
                warn "l'extraction s'est terminee mais '$RunBat' est introuvable - archive incomplete ou corrompue. Supprimez '$Archive' et relancez le script."
                $ComfyStatus = 'echec (extraction)'
            }
        }
    }
}

# ---------------------------------------------------------------------------
section '3/7 comfy_kitchen (acceleration optionnelle)'
# ---------------------------------------------------------------------------
if (-not (Test-Path $PythonEmbed)) {
    warn "python_embeded introuvable ($PythonEmbed) - installation de comfy_kitchen ignoree."
    $KitchenStatus = 'ignore (ComfyUI portable absent)'
} else {
    Write-Host 'Installation de comfy_kitchen dans le Python embarque de ComfyUI (wheel precompilee win_amd64, aucune compilation requise).'
    & $PythonEmbed -m pip install comfy_kitchen
    if ($LASTEXITCODE -eq 0) {
        Write-Host 'OK: comfy_kitchen disponible.'
        $KitchenStatus = 'installe'
    } else {
        warn "acceleration optionnelle non installee (pip code $LASTEXITCODE - reseau ou proxy ?)."
        Write-Host "  Ce n'est PAS un prerequis : le node core ModelAttentionBackend de ComfyUI bascule"
        Write-Host "  automatiquement sur 'pytorch attention' quand comfy_kitchen est absent (simple"
        Write-Host '  avertissement dans les logs ComfyUI). Tout fonctionne, un peu moins vite.'
        $KitchenStatus = 'non installe (optionnel, degradation auto vers pytorch attention)'
    }
}

# ---------------------------------------------------------------------------
section '4/7 Telechargement des modeles (scripts/models.txt)'
# ---------------------------------------------------------------------------
if (-not (Test-Path $ModelsFile)) {
    Write-Host 'scripts\models.txt introuvable - aucun modele a telecharger.'
} elseif (-not (Test-Path $Portable)) {
    warn 'ComfyUI portable absent - telechargement des modeles reporte. Relancez le script une fois ComfyUI installe.'
} else {
    foreach ($rawLine in (Get-Content $ModelsFile)) {
        $line = $rawLine.Trim()
        if ($line -eq '' -or $line.StartsWith('#')) { continue }

        $parts = $line.Split('|')
        if ($parts.Count -lt 4) { continue }

        $dossier = $parts[0].Trim().Replace('/', '\')
        $fichier = $parts[1].Trim()
        $taille  = $parts[2].Trim()
        $url     = $parts[3].Trim()

        $targetDir  = Join-Path $ModelsDir $dossier
        $targetPath = Join-Path $targetDir $fichier

        if ($url -eq '' -or $url -eq 'NON_TROUVE') {
            $Manual += $targetPath
            continue
        }

        $expected = $taille -as [long]
        if ($null -eq $expected) { $expected = 0 }

        if ((Test-Path $targetPath) -and ($expected -gt 0)) {
            $actual = (Get-Item $targetPath).Length
            $diff = [Math]::Abs($actual - $expected)
            $tolerance = [Math]::Max([long]($expected / 100), 1)
            if ($diff -le $tolerance) {
                Write-Host "SKIP (deja present, taille conforme): $targetPath"
                $Skipped += $targetPath
                continue
            }
        }

        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        Write-Host ''
        Write-Host "Telechargement: $fichier -> $targetPath"

        # Certains depots Hugging Face (ex. Lightricks/LTX-2.5) sont "gated" : un
        # telechargement anonyme echoue en 401 tant que les conditions n'ont pas ete
        # acceptees sur huggingface.co avec un compte et qu'un jeton n'est pas fourni.
        # Si HF_TOKEN est defini, on l'utilise ; sinon l'echec remonte proprement dans
        # le recapitulatif sans bloquer les autres telechargements.
        $curlArgs = @('-L', '-C', '-', '--fail', '-o', $targetPath, $url)
        if ($env:HF_TOKEN -and ($url -like '*huggingface.co*')) {
            $curlArgs = @('-L', '-C', '-', '--fail', '-H', "Authorization: Bearer $($env:HF_TOKEN)", '-o', $targetPath, $url)
        }

        & curl.exe $curlArgs
        if ($LASTEXITCODE -eq 0) {
            $Downloaded += $targetPath
        } else {
            warn "echec du telechargement de '$fichier' (curl code $LASTEXITCODE)"
            $Failed += "$targetPath ($url)"
        }
    }
}

# ---------------------------------------------------------------------------
section '5/7 Ollama'
# ---------------------------------------------------------------------------
# Ollama est peut-etre DEJA installe sur ce poste : on ne suppose jamais son absence.
# (a) le service repond deja -> on ne touche a rien
# (b) installe mais eteint    -> on tente de le demarrer
# (c) vraiment introuvable    -> on guide l'utilisateur, sans installer a sa place

# Chemin du binaire resolu une seule fois : sert aussi bien a (b) qu'au pull plus bas.
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
    Write-Host 'OK: Ollama repond deja sur :11434 - reutilisation, rien a faire.'
    $OllamaStatus = 'deja en service'
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
        Write-Host 'Attente de la disponibilite du service (5 tentatives, 2 s d''intervalle)...'
        for ($i = 1; $i -le 5; $i++) {
            Start-Sleep -Seconds 2
            if (Test-Http 'http://localhost:11434/api/version') {
                $OllamaUp = $true
                break
            }
            Write-Host "  tentative $i/5 - pas encore de reponse sur :11434"
        }
        if ($OllamaUp) {
            Write-Host 'OK: Ollama demarre et repond sur :11434.'
            $OllamaStatus = 'demarre par ce script'
        } else {
            warn 'Ollama a ete lance mais ne repond toujours pas sur :11434 apres 5 tentatives.'
            Write-Host '  Verifiez l''icone Ollama dans la zone de notification, puis relancez ce script.'
            $OllamaStatus = 'lance mais sans reponse sur :11434'
        }
    } else {
        # (c) ------------------------------------------------------------
        warn 'Ollama introuvable sur ce poste (ni en service, ni installe).'
        Write-Host "  Telechargez et lancez l'installeur officiel : $OllamaSetup"
        Write-Host '  Puis relancez ce script : il detectera Ollama et poursuivra la configuration.'
        Write-Host "  (ce script n'installe volontairement aucun composant systeme a votre place)"
        $OllamaStatus = 'absent (installation manuelle requise)'
    }
}

# Modele gemma4:e4b - uniquement si le service repond.
if (-not $OllamaUp) {
    $GemmaStatus = 'non verifie (Ollama indisponible)'
} else {
    $tags = & curl.exe -s --max-time 10 'http://localhost:11434/api/tags'
    if ("$tags" -like '*"gemma4:e4b"*') {
        Write-Host 'OK: gemma4:e4b deja present - pas de retelechargement.'
        $GemmaStatus = 'present'
    } elseif ($OllamaCli -eq '') {
        warn "le service Ollama repond mais le binaire 'ollama' est introuvable - impossible de lancer le pull automatiquement."
        Write-Host '  Lancez manuellement : ollama pull gemma4:e4b'
        $GemmaStatus = 'absent (pull manuel requis)'
    } else {
        Write-Host 'gemma4:e4b absent - telechargement en cours (peut prendre plusieurs minutes)...'
        & $OllamaCli pull gemma4:e4b
        if ($LASTEXITCODE -eq 0) {
            $GemmaStatus = 'telecharge'
        } else {
            warn "echec du pull de gemma4:e4b (code $LASTEXITCODE)."
            $GemmaStatus = 'echec'
        }
    }
}

# ---------------------------------------------------------------------------
section '6/7 Demarrage des services'
# ---------------------------------------------------------------------------
Write-Host '--- ComfyUI (:8188) ---'
if (Test-Http 'http://localhost:8188/system_stats') {
    Write-Host 'ComfyUI repond deja sur :8188 - reutilisation, pas de relance.'
} elseif (-not (Test-Path $RunBat)) {
    warn "'$RunBat' introuvable - ComfyUI ne peut pas etre demarre (voir section 2/7)."
} else {
    Write-Host "Demarrage de ComfyUI : $RunBat"
    Start-Process -FilePath $RunBat -WorkingDirectory $Portable
    Write-Host '  (ComfyUI ecoute sur 127.0.0.1:8188 ; le premier demarrage peut prendre une minute)'
}

Write-Host ''
Write-Host '--- Serveur web + proxy (:8090) ---'
if (Test-Http 'http://localhost:8090/') {
    Write-Host 'Le serveur web repond deja sur :8090 - reutilisation, pas de relance.'
    $WebStatus = 'deja en service'
} elseif (-not (Test-Path $ServeScript)) {
    warn "'$ServeScript' introuvable - le serveur web ne peut pas etre demarre."
    $WebStatus = 'echec (scripts\serve-windows.ps1 absent)'
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
Write-Host "  - deja presents (non retelecharges) : $($Skipped.Count)"
Write-Host "  - telecharges cette execution       : $($Downloaded.Count)"
if ($Failed.Count -gt 0) {
    Write-Host '  - echecs de telechargement :'
    foreach ($f in $Failed) { Write-Host "      $f" }
    Write-Host "    (si l'echec concerne un fichier Lightricks/LTX-2.5 : ce depot Hugging Face est"
    Write-Host "    'gated' - acceptez les conditions sur sa page HF avec votre compte, puis relancez"
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
Write-Host 'Ce script est relancable a volonte : rien de deja present et valide ne sera retelecharge.'
