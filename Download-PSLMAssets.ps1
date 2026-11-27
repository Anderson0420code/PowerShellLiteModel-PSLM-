param(
    [ValidateSet('engine-cpu','engine-cuda','model-cpu','model-cuda')]
    [Parameter(Mandatory)]
    [string]$Asset,
    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string]$Url,
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$Sha256,
    [switch]$Extract
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$allowedHosts = @(
    'github.com',
    'objects.githubusercontent.com',
    'release-assets.githubusercontent.com',
    'huggingface.co',
    'cdn-lfs.hf.co',
    'cdn-lfs.huggingface.co',
    'cas-bridge.xethub.hf.co'
)

function Test-ApprovedHost([System.Uri]$Uri) {
    return $Uri.Scheme -eq 'https' -and
        [string]::IsNullOrEmpty($Uri.UserInfo) -and
        $Uri.Host -in $allowedHosts
}

function Get-ApprovedWebResponse([System.Uri]$InitialUri) {
    $currentUri = $InitialUri
    for ($redirect = 0; $redirect -le 5; $redirect++) {
        if (-not (Test-ApprovedHost $currentUri)) {
            throw "Refusing download URL or redirect to unapproved HTTPS host: $($currentUri.Host)"
        }

        $request = [System.Net.HttpWebRequest]::Create($currentUri)
        $request.AllowAutoRedirect = $false
        $request.UserAgent = 'PSLM-Asset-Downloader'
        $request.Timeout = 30000
        $request.ReadWriteTimeout = 120000

        try {
            $response = $request.GetResponse()
        } catch [System.Net.WebException] {
            $response = $_.Exception.Response
            if (-not $response) {
                throw
            }
        }

        $status = [int]$response.StatusCode
        if ($status -ge 300 -and $status -lt 400) {
            $location = $response.Headers[[System.Net.HttpResponseHeader]::Location]
            $response.Close()
            if ([string]::IsNullOrEmpty($location) -or $redirect -eq 5) {
                throw 'Download exceeded the allowed redirect limit.'
            }
            $currentUri = [System.Uri]::new($currentUri, $location)
            continue
        }
        if ($status -ne 200) {
            $response.Close()
            throw "Download failed with HTTP status $status."
        }
        return $response
    }
    throw 'Download exceeded the allowed redirect limit.'
}

$uri = [System.Uri]$Url
if (-not (Test-ApprovedHost $uri)) {
    throw "Refusing unapproved download host: $($uri.Host)"
}

$destination = switch ($Asset) {
    'engine-cpu' { Join-Path $root 'bin_cpu' }
    'engine-cuda' { Join-Path $root 'bin_cuda' }
    'model-cpu' { Join-Path $root 'models' }
    'model-cuda' { Join-Path $root 'models' }
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null

$extension = [System.IO.Path]::GetExtension($uri.AbsolutePath)
$fileName = if ($Asset -like 'model-*') { if ($Asset -eq 'model-cpu') { 'cpu-model.gguf' } else { 'cuda-model.gguf' } } else { "pslm-$Asset$extension" }
$downloadPath = Join-Path $env:TEMP ("pslm-" + [guid]::NewGuid().ToString('N') + '-' + $fileName)
$tempExtract = $null

try {
    Write-Host "Downloading $Asset from approved host $($uri.Host)..."
    $response = $null
    $inputStream = $null
    $outputStream = $null
    try {
        $response = Get-ApprovedWebResponse $uri
        $inputStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Open(
            $downloadPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
    }

    if ($Sha256) {
        $actual = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $Sha256.ToLowerInvariant()) {
            throw "SHA-256 mismatch. Download deleted."
        }
    }

    if ($Extract) {
        if ($extension -ine '.zip') {
            throw "The -Extract switch requires a .zip asset."
        }
        $tempExtract = Join-Path $env:TEMP ("pslm-$Asset-" + [guid]::NewGuid())
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $tempExtract -Force
        $installedEngine = Get-ChildItem -LiteralPath $tempExtract -Recurse -File | Where-Object {
            $_.Name -ieq 'llama-server.exe'
        }
        if (-not $installedEngine) {
            throw "Archive does not contain llama-server.exe."
        }
        Get-ChildItem -LiteralPath $tempExtract -Recurse -File | Where-Object {
            $_.Name -ieq 'llama-server.exe' -or $_.Extension -in @('.dll','.so')
        } | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
        }
    } else {
        Copy-Item -LiteralPath $downloadPath -Destination (Join-Path $destination $fileName) -Force
    }

    Write-Host "Installed $Asset into $destination"
}
finally {
    if ($tempExtract -and (Test-Path -LiteralPath $tempExtract)) {
        Remove-Item -LiteralPath $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $downloadPath) {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
}
