<#
    serve-windows.ps1 — native Windows equivalent of `nginx.conf` (100% native variant, no Docker).

    Serves the repository's static files on port 8090 AND relays /comfy/* to ComfyUI
    (127.0.0.1:8188) and /ollama/* to Ollama (127.0.0.1:11434). This reverse proxy is
    mandatory: the frontend (index.html, canvas.html, js/engine.js) calls these APIs through
    RELATIVE paths (`/comfy/prompt`, `/ollama/api/chat`), never `localhost:8188` — a plain
    static file server would therefore not be enough.

    Targets Windows PowerShell 5.1 (.NET Framework). Zero dependency, zero module to install.

    Usage:
        powershell -ExecutionPolicy Bypass -File .\scripts\serve-windows.ps1
        powershell -ExecutionPolicy Bypass -File .\scripts\serve-windows.ps1 -SelfTest

    Mapping to nginx.conf:
        location /comfy/ws   -> 501, NOT implemented (see below)
        location /comfy/     -> proxy 127.0.0.1:$ComfyPort  (GET + POST, binary)
        location /ollama/    -> proxy 127.0.0.1:$OllamaPort (POST JSON, long timeout)
        location /update/    -> NOT implemented: no dedicated route, falls into the static
                                404. js/update-check.js already swallows the error
                                (`.catch(() => {})`), the git updater belongs to Docker Linux.
        location /           -> static files under $Root
#>

param([string]$Root, [int]$Port = 8090, [int]$ComfyPort = 8188, [int]$OllamaPort = 11434, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'

# Avoids the "100-continue" round-trip on every POST (image upload, ComfyUI prompt).
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

# ── Static path resolution, directory-traversal guard ───────────────────────────────────
# Returns the absolute path of the requested file, or $null if the request escapes $RootDir.
# Invariant checked by -SelfTest: the result is ALWAYS $null or strictly under $RootDir.
function Resolve-StaticPath {
    param([string]$RootDir, [string]$UrlPath)

    # Any parent-directory segment is refused before normalisation even happens.
    if ($UrlPath -like '*..*') { return $null }

    $rel = $UrlPath.TrimStart('/')
    # nginx's `try_files $uri $uri/ =404` + `index index.html`: "/" serves index.html.
    if ($rel -eq '' -or $UrlPath.EndsWith('/')) { $rel = $rel + 'index.html' }
    $rel = $rel.Replace('/', [System.IO.Path]::DirectorySeparatorChar)

    $base = [System.IO.Path]::GetFullPath($RootDir).TrimEnd([System.IO.Path]::DirectorySeparatorChar) +
            [System.IO.Path]::DirectorySeparatorChar
    try {
        # Second barrier: compare the NORMALISED path against the normalised root.
        $full = [System.IO.Path]::GetFullPath((Join-Path $RootDir $rel))
    } catch {
        # Invalid path (injected drive letter, forbidden character…): refuse.
        return $null
    }
    if (-not $full.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

# ── Construction de l'URL cible d'un proxy ──────────────────────────────────────────────
# Reproduces `proxy_pass http://127.0.0.1:PORT/;`: the prefix (/comfy, /ollama) is stripped,
# the rest of the path AND the query string are forwarded as is, encoding included.
function Get-ProxyTarget {
    param([string]$RawUrl, [string]$Prefix, [int]$TargetPort)

    $tail = $RawUrl.Substring($Prefix.Length)
    if (-not $tail.StartsWith('/')) { $tail = '/' + $tail }
    return "http://127.0.0.1:$TargetPort$tail"
}

# ── Generic relay (ComfyUI and Ollama share this single code path) ──────────────────────
# IMPORTANT: request AND response bodies are handled as byte[] end to end. No string
# conversion here — the multipart upload of /comfy/upload/image (up to 50 MB) and the
# images/videos returned by /comfy/view would be corrupted by a text round-trip.
function Invoke-Proxy {
    param($Context, [string]$Prefix, [int]$TargetPort, [int]$TimeoutMs)

    $req = $Context.Request
    $res = $Context.Response
    $target = Get-ProxyTarget -RawUrl $req.RawUrl -Prefix $Prefix -TargetPort $TargetPort

    # Incoming body: read as bytes from the listener (no artificial limit, nginx
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
    # Content-Type copied verbatim: it carries the upload multipart's `boundary=...`.
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
        # ComfyUI answers 400 + an error JSON the frontend reads (`data.error` in
        # engine.js submitGraph): that body must be relayed, not hidden behind a 502.
        $resp = $_.Exception.Response
        if ($null -eq $resp) {
            $msg = [System.Text.Encoding]::UTF8.GetBytes(
                "Service unreachable on 127.0.0.1:$TargetPort ($($_.Exception.Message))")
            $res.StatusCode = 502
            $res.ContentType = 'text/plain; charset=utf-8'
            $res.ContentLength64 = $msg.Length
            $res.OutputStream.Write($msg, 0, $msg.Length)
            return 502
        }
    }

    # Outgoing body: raw bytes, no reinterpretation.
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

# ── Self-test (not run by default) ──────────────────────────────────────────────────────
if ($SelfTest) {
    $failures = 0
    # Write-Host et non Write-Error : $ErrorActionPreference='Stop' rendrait Write-Error
    # exiting, we want to count EVERY failure. The exit code is what matters.
    function Fail { param([string]$Msg) Write-Host "ECHEC : $Msg" -ForegroundColor Red; $script:failures++ }

    $testRoot = [System.IO.Path]::GetFullPath((Join-Path ([System.IO.Path]::GetTempPath()) 'acs-selftest-root'))
    $base = $testRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar

    # 1. Traversal guard: none of these requests may resolve outside $testRoot.
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
            Fail "TRAVERSAL: '$p' resolves outside the root -> $r"
        }
    }

    # 2. Legitimate paths: must resolve under the root.
    $legit = @{ '/' = 'index.html'; '/index.html' = 'index.html'; '/js/engine.js' = 'engine.js';
                '/workflows/api/ltx25_t2v.json' = 'ltx25_t2v.json' }
    foreach ($p in $legit.Keys) {
        $r = Resolve-StaticPath -RootDir $testRoot -UrlPath $p
        if ($null -eq $r -or -not $r.StartsWith($base, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not $r.EndsWith($legit[$p])) {
            Fail "LEGITIMATE PATH: '$p' -> '$r' (expected under $base, ending with $($legit[$p]))"
        }
    }

    # 3. Relay: prefix stripped, path and query string (encoding included) preserved.
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

    if ($failures -gt 0) { Write-Host "SelfTest: $failures failure(s)." -ForegroundColor Red; exit 1 }
    Write-Host 'SelfTest : OK.' -ForegroundColor Green
    exit 0
}

# ── Startup ─────────────────────────────────────────────────────────────────────────────
if (-not $Root) {
    # The script lives in scripts/: the served root is the repo, one level above.
    if ($PSScriptRoot) { $Root = Split-Path -Parent $PSScriptRoot } else { $Root = (Get-Location).Path }
}
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    # Write-Host and not Write-Error: with $ErrorActionPreference='Stop', Write-Error
    # would terminate before the `exit 1` and the exit code would be less predictable.
    Write-Host "Root not found: $Root" -ForegroundColor Red
    exit 1
}
$Root = (Resolve-Path -LiteralPath $Root).Path

$listener = New-Object System.Net.HttpListener
# `http://localhost:PORT/` is an http.sys special case: NO urlacl and no administrator
# rights required. Accepted consequence: access limited to this machine (no LAN).
# To open local network access, run ONCE as administrator (not done here):
#     netsh http add urlacl url=http://+:8090/ user=DOMAINE\utilisateur
# then replace the prefix below with "http://+:$Port/". A Windows firewall rule allowing
# inbound port 8090 is required as well.
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()

Write-Host "AI Content Studio — http://localhost:$Port/" -ForegroundColor Cyan
Write-Host "  racine   : $Root"
Write-Host "  /comfy/  -> http://127.0.0.1:$ComfyPort/"
Write-Host "  /ollama/ -> http://127.0.0.1:$OllamaPort/"
Write-Host '  Ctrl+C to stop.'

try {
    # Boucle mono-thread : un seul poste, un seul utilisateur. Pas de runspaces, pas d'async.
    while ($listener.IsListening) {
        $ctx = $listener.GetContext()
        $code = 0
        $line = "$($ctx.Request.HttpMethod) $($ctx.Request.RawUrl)"
        try {
            $path = $ctx.Request.Url.LocalPath

            if ($path -eq '/comfy/ws') {
                # OUT OF SCOPE: the ComfyUI WebSocket only feeds the progress bar
                # (engine.js says so itself: "best-effort, purely cosmetic"), and its
                # `onclose` retries every 4 s without breaking the app. We answer cleanly
                # rather than letting an unhandled exception escape.
                $code = Write-Plain $ctx.Response 501 'WebSocket not supported by serve-windows.ps1 (cosmetic progress only).'
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
            # Unreachable target, browser cancelling an image load…: log it and carry on,
            # the loop must not die on a single request.
            Write-Host "  error: $($_.Exception.Message)" -ForegroundColor Red
            try { $ctx.Response.StatusCode = 500 } catch { }
            $code = 500
        } finally {
            try { $ctx.Response.Close() } catch { }
        }
        Write-Host "$line -> $code"
    }
} finally {
    # Ctrl+C: http.sys releases the port reservation as soon as the listener is closed (and
    # anyway when the process ends), so port 8090 is not left blocked.
    $listener.Stop()
    $listener.Close()
    Write-Host 'Serveur arrete.'
}
