<#
    serve-windows.ps1 — équivalent Windows natif de `nginx.conf` (variante 100 % native, sans Docker).

    Sert les fichiers statiques du dépôt sur le port 8090 ET relaie /comfy/* vers ComfyUI
    (127.0.0.1:8188) et /ollama/* vers Ollama (127.0.0.1:11434). Ce reverse-proxy est
    indispensable : le frontend (index.html, canvas.html, js/engine.js) appelle ces API en
    chemins RELATIFS (`/comfy/prompt`, `/ollama/api/chat`), jamais en `localhost:8188` —
    un simple serveur de fichiers statiques ne suffirait donc pas.

    Cible : Windows PowerShell 5.1 (.NET Framework). Zéro dépendance, zéro module à installer.

    Usage :
        powershell -ExecutionPolicy Bypass -File .\scripts\serve-windows.ps1
        powershell -ExecutionPolicy Bypass -File .\scripts\serve-windows.ps1 -SelfTest

    Correspondance avec nginx.conf :
        location /comfy/ws   -> 501, NON implémenté (voir plus bas)
        location /comfy/     -> proxy 127.0.0.1:$ComfyPort  (GET + POST, binaire)
        location /ollama/    -> proxy 127.0.0.1:$OllamaPort (POST JSON, timeout long)
        location /update/    -> NON implémenté : pas de route dédiée, tombe dans le 404
                                statique. js/update-check.js avale déjà l'erreur
                                (`.catch(() => {})`), l'updater git est propre au Docker Linux.
        location /           -> fichiers statiques sous $Root
#>

param([string]$Root, [int]$Port = 8090, [int]$ComfyPort = 8188, [int]$OllamaPort = 11434, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# Évite le round-trip « 100-continue » sur chaque POST (upload d'image, prompt ComfyUI).
[System.Net.ServicePointManager]::Expect100Continue = $false

$MimeTypes = @{
    '.html' = 'text/html; charset=utf-8'
    '.htm'  = 'text/html; charset=utf-8'
    '.js'   = 'text/javascript; charset=utf-8'
    '.mjs'  = 'text/javascript; charset=utf-8'
    '.css'  = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'
    '.svg'  = 'image/svg+xml'
    '.png'  = 'image/png'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.gif'  = 'image/gif'
    '.webp' = 'image/webp'
    '.ico'  = 'image/x-icon'
    '.mp4'  = 'video/mp4'
    '.webm' = 'video/webm'
    '.txt'  = 'text/plain; charset=utf-8'
    '.md'   = 'text/plain; charset=utf-8'
}

# ── Résolution de chemin statique, anti-traversée de répertoire ─────────────────────────
# Renvoie le chemin absolu du fichier demandé, ou $null si la demande sort de $RootDir.
# Invariant vérifié par -SelfTest : le retour est TOUJOURS $null ou strictement sous $RootDir.
function Resolve-StaticPath {
    param([string]$RootDir, [string]$UrlPath)

    # Tout segment de remontée est refusé avant même la normalisation.
    if ($UrlPath -like '*..*') { return $null }

    $rel = $UrlPath.TrimStart('/')
    # `try_files $uri $uri/ =404` + `index index.html` côté nginx : "/" sert index.html.
    if ($rel -eq '' -or $UrlPath.EndsWith('/')) { $rel = $rel + 'index.html' }
    $rel = $rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar)

    $base = [System.IO.Path]::GetFullPath($RootDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
            [System.IO.Path]::DirectorySeparatorChar
    try {
        # Deuxième barrière : on compare le chemin NORMALISÉ à la racine normalisée.
        $full = [System.IO.Path]::GetFullPath((Join-Path $RootDir $rel))
    } catch {
        # Chemin invalide (lettre de lecteur injectée, caractère interdit…) : refus.
        return $null
    }
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

# ── Construction de l'URL cible d'un proxy ──────────────────────────────────────────────
# Reproduit `proxy_pass http://127.0.0.1:PORT/;` : le préfixe (/comfy, /ollama) est retiré,
# le reste du chemin ET la query string sont transmis tels quels, encodage compris.
function Get-ProxyTarget {
    param([string]$RawUrl, [string]$Prefix, [int]$TargetPort)

    $tail = $RawUrl.Substring($Prefix.Length)
    if (-not $tail.StartsWith('/')) { $tail = '/' + $tail }
    return "http://127.0.0.1:$TargetPort$tail"
}

# ── Relais générique (ComfyUI et Ollama partagent ce seul chemin de code) ────────────────
# IMPORTANT : corps de requête ET de réponse manipulés en byte[] de bout en bout. Aucune
# conversion en string ici — l'upload multipart de /comfy/upload/image (jusqu'à 50 Mo) et
# les images/vidéos rendues par /comfy/view seraient corrompus par un aller-retour texte.
function Invoke-Proxy {
    param($Context, [string]$Prefix, [int]$TargetPort, [int]$TimeoutMs)

    $req = $Context.Request
    $res = $Context.Response
    $target = Get-ProxyTarget -RawUrl $req.RawUrl -Prefix $Prefix -TargetPort $TargetPort

    # Corps entrant : lu en bytes depuis le listener (pas de limite artificielle, nginx
    # autorise `client_max_body_size 50m`).
    $body = $null
    if ($req.HasEntityBody) {
        $ms = New-Object System.IO.MemoryStream
        $req.InputStream.CopyTo($ms)
        $body = $ms.ToArray()
        $ms.Dispose()
    }

    $out = [System.Net.HttpWebRequest][System.Net.WebRequest]::Create($target)
    $out.Method = $req.HttpMethod
    $out.Timeout = $TimeoutMs
    $out.ReadWriteTimeout = $TimeoutMs
    $out.AllowAutoRedirect = $false
    # Content-Type recopié à l'identique : porte le `boundary=...` du multipart d'upload.
    if ($req.ContentType) { $out.ContentType = $req.ContentType }

    if ($body -and $body.Length -gt 0) {
        $out.ContentLength = $body.Length
        $reqStream = $out.GetRequestStream()
        $reqStream.Write($body, 0, $body.Length)
        $reqStream.Close()
    } elseif ($out.Method -eq 'POST') {
        $out.ContentLength = 0
    }

    $resp = $null
    try {
        $resp = $out.GetResponse()
    } catch [System.Net.WebException] {
        # ComfyUI répond 400 + un JSON d'erreur que le frontend lit (`data.error` dans
        # engine.js submitGraph) : il faut relayer ce corps, pas le masquer par un 502.
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            $msg = [System.Text.Encoding]::UTF8.GetBytes(
                "Service injoignable sur 127.0.0.1:$TargetPort ($($_.Exception.Message))")
            $res.StatusCode = 502
            $res.ContentType = 'text/plain; charset=utf-8'
            $res.ContentLength64 = $msg.Length
            $res.OutputStream.Write($msg, 0, $msg.Length)
            return 502
        }
    }

    # Corps sortant : bytes bruts, aucune réinterprétation.
    $ms = New-Object System.IO.MemoryStream
    $resp.GetResponseStream().CopyTo($ms)
    $bytes = $ms.ToArray()
    $ms.Dispose()

    $code = [int]$resp.StatusCode
    $res.StatusCode = $code
    if ($resp.ContentType) { $res.ContentType = $resp.ContentType }
    $res.ContentLength64 = $bytes.Length
    if ($bytes.Length -gt 0) { $res.OutputStream.Write($bytes, 0, $bytes.Length) }
    $resp.Close()
    return $code
}

function Write-Plain {
    param($Response, [int]$Code, [string]$Text)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $Response.StatusCode = $Code
    $Response.ContentType = 'text/plain; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
    return $Code
}

# ── Auto-test (non exécuté par défaut) ──────────────────────────────────────────────────
if ($SelfTest) {
    $failures = 0
    # Write-Host et non Write-Error : $ErrorActionPreference='Stop' rendrait Write-Error
    # terminant, on veut compter TOUS les echecs. Le code de sortie fait foi.
    function Fail { param([string]$Msg) Write-Host "ECHEC : $Msg" -ForegroundColor Red; $script:failures++ }

    $testRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'acs-selftest-root'))
    $base = $testRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

    # 1. Anti-traversée : aucune de ces demandes ne doit résoudre hors de $testRoot.
    $hostile = @(
        '/../../etc/passwd',
        '/../../../Windows/System32/drivers/etc/hosts',
        '/js/../../secrets.txt',
        '/..\..\Windows\win.ini',
        '/C:/Windows/win.ini',
        '//server/share/file.txt',
        '/....//....//etc/passwd'
    )
    foreach ($p in $hostile) {
        $r = Resolve-StaticPath -RootDir $testRoot -UrlPath $p
        if ($null -ne $r -and -not $r.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) {
            Fail "TRAVERSEE : '$p' resout hors de la racine -> $r"
        }
    }

    # 2. Chemins légitimes : doivent résoudre sous la racine.
    $legit = @{ '/' = 'index.html'; '/index.html' = 'index.html'; '/js/engine.js' = 'engine.js';
                '/workflows/api/ltx25_t2v.json' = 'ltx25_t2v.json' }
    foreach ($p in $legit.Keys) {
        $r = Resolve-StaticPath -RootDir $testRoot -UrlPath $p
        if ($null -eq $r -or -not $r.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $r.EndsWith($legit[$p])) {
            Fail "CHEMIN LEGITIME : '$p' -> '$r' (attendu sous $base, finissant par $($legit[$p]))"
        }
    }

    # 3. Relais : préfixe retiré, chemin et query string (encodage compris) préservés.
    $targets = @{
        '/comfy/prompt'                              = 'http://127.0.0.1:8188/prompt'
        '/comfy/upload/image'                        = 'http://127.0.0.1:8188/upload/image'
        '/comfy/view?filename=a%20b.png&type=output' = 'http://127.0.0.1:8188/view?filename=a%20b.png&type=output'
        '/comfy/history/abc?max_items=24'            = 'http://127.0.0.1:8188/history/abc?max_items=24'
    }
    foreach ($u in $targets.Keys) {
        $got = Get-ProxyTarget -RawUrl $u -Prefix '/comfy' -TargetPort 8188
        if ($got -ne $targets[$u]) {
            Fail "RELAIS : '$u' -> '$got' (attendu '$($targets[$u])')"
        }
    }
    $got = Get-ProxyTarget -RawUrl '/ollama/api/chat' -Prefix '/ollama' -TargetPort 11434
    if ($got -ne 'http://127.0.0.1:11434/api/chat') {
        Fail "RELAIS : '/ollama/api/chat' -> '$got'"
    }

    if ($failures -gt 0) { Write-Host "SelfTest : $failures echec(s)." -ForegroundColor Red; exit 1 }
    Write-Host 'SelfTest : OK.' -ForegroundColor Green
    exit 0
}

# ── Démarrage ───────────────────────────────────────────────────────────────────────────
if (-not $Root) {
    # Le script vit dans scripts/ : la racine servie est le dépôt, un niveau au-dessus.
    if ($PSScriptRoot) { $Root = Split-Path -Parent $PSScriptRoot } else { $Root = (Get-Location).Path }
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    # Write-Host et non Write-Error : avec $ErrorActionPreference='Stop', Write-Error
    # terminerait avant le `exit 1` et le code de sortie serait moins previsible.
    Write-Host "Racine introuvable : $Root" -ForegroundColor Red
    exit 1
}
$Root = (Resolve-Path -LiteralPath $Root).Path

$listener = New-Object System.Net.HttpListener
# `http://localhost:PORT/` est un cas spécial d'http.sys : PAS de urlacl ni de droits
# administrateur requis. Conséquence assumée : accès limité à cette machine (pas de LAN).
# Pour ouvrir l'accès réseau local, exécuter UNE FOIS en administrateur (non fait ici) :
#     netsh http add urlacl url=http://+:8090/ user=DOMAINE\utilisateur
# puis remplacer le préfixe ci-dessous par "http://+:$Port/". Une règle de pare-feu Windows
# autorisant le port 8090 en entrée est également nécessaire.
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "AI Content Studio — http://localhost:$Port/" -ForegroundColor Cyan
Write-Host "  racine   : $Root"
Write-Host "  /comfy/  -> http://127.0.0.1:$ComfyPort/"
Write-Host "  /ollama/ -> http://127.0.0.1:$OllamaPort/"
Write-Host '  Ctrl+C pour arreter.'

try {
    # Boucle mono-thread : un seul poste, un seul utilisateur. Pas de runspaces, pas d'async.
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $code = 0
        $line = "$($ctx.Request.HttpMethod) $($ctx.Request.RawUrl)"
        try {
            $path = $ctx.Request.Url.LocalPath

            if ($path -eq '/comfy/ws') {
                # HORS SCOPE : le WebSocket ComfyUI n'alimente que la barre de progression
                # (engine.js le dit lui-même : « best-effort, purement cosmétique »), et son
                # `onclose` retente toutes les 4 s sans casser l'app. On répond proprement
                # plutôt que de laisser une exception non gérée.
                $code = Write-Plain $ctx.Response 501 'WebSocket non supporte par serve-windows.ps1 (progression cosmetique uniquement).'
            }
            elseif ($path.StartsWith('/comfy/')) {
                $code = Invoke-Proxy -Context $ctx -Prefix '/comfy' -TargetPort $ComfyPort -TimeoutMs 120000
            }
            elseif ($path.StartsWith('/ollama/')) {
                # gemma4:e4b peut mettre plusieurs dizaines de secondes a repondre a froid.
                $code = Invoke-Proxy -Context $ctx -Prefix '/ollama' -TargetPort $OllamaPort -TimeoutMs 300000
            }
            else {
                $file = Resolve-StaticPath -RootDir $Root -UrlPath $path
                if ($null -eq $file -or -not (Test-Path -LiteralPath $file -PathType Leaf)) {
                    $code = Write-Plain $ctx.Response 404 'Not Found'
                } else {
                    $bytes = [System.IO.File]::ReadAllBytes($file)
                    $ext = [System.IO.Path]::GetExtension($file).ToLowerInvariant()
                    $type = $MimeTypes[$ext]
                    if (-not $type) { $type = 'application/octet-stream' }
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.ContentType = $type
                    $ctx.Response.ContentLength64 = $bytes.Length
                    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $code = 200
                }
            }
        } catch {
            # Cible injoignable, navigateur qui annule un chargement d'image… : on logue et
            # on continue, la boucle ne doit pas mourir sur une requete.
            Write-Host "  erreur: $($_.Exception.Message)" -ForegroundColor Red
            try { $ctx.Response.StatusCode = 500 } catch { }
            $code = 500
        } finally {
            try { $ctx.Response.Close() } catch { }
        }
        Write-Host "$line -> $code"
    }
} finally {
    # Ctrl+C : http.sys libere la reservation du port des la fermeture du listener (et de
    # toute facon a la fin du processus), le port 8090 ne reste pas bloque.
    $listener.Stop()
    $listener.Close()
    Write-Host 'Serveur arrete.'
}
