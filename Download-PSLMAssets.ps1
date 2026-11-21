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
    'cdn-lfs.hf.co'
)
$uri = [uri]$Url
if ($uri.Host -notin $allowedHosts) {
    throw "Refusing unapproved download host: $($uri.Host)"
}

$configuration = Get-Content -LiteralPath (Join-Path $root 'models.json') -Raw | ConvertFrom-Json
$destination = switch ($Asset) {
    'engine-cpu' { Join-Path $root 'bin_cpu' }
    'engine-cuda' { Join-Path $root 'bin_cuda' }
    'model-cpu' { Join-Path $root 'models' }
    'model-cuda' { Join-Path $root 'models' }
}
New-Item -ItemType Directory -Path $destination -Force | Out-Null

$extension = [System.IO.Path]::GetExtension($uri.AbsolutePath)
$fileName = if ($Asset -like 'model-*') { if ($Asset -eq 'model-cpu') { 'cpu-model.gguf' } else { 'cuda-model.gguf' } } else { "pslm-$Asset$extension" }
$downloadPath = Join-Path $env:TEMP $fileName

Write-Host "Downloading $Asset from approved host $($uri.Host)..."
Invoke-WebRequest -Uri $Url -OutFile $downloadPath -MaximumRedirection 5 -UseBasicParsing

if ($Sha256) {
    $actual = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Sha256.ToLowerInvariant()) {
        Remove-Item -LiteralPath $downloadPath -Force
        throw "SHA-256 mismatch. Download deleted."
    }
}

if ($Extract) {
    $tempExtract = Join-Path $env:TEMP ("pslm-$Asset-" + [guid]::NewGuid())
    Expand-Archive -LiteralPath $downloadPath -DestinationPath $tempExtract -Force
    Get-ChildItem -LiteralPath $tempExtract -Recurse -File | Where-Object {
        $_.Name -ieq 'llama-server.exe' -or $_.Extension -in @('.dll','.so')
    } | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination $destination -Force
    }
    Remove-Item -LiteralPath $tempExtract -Recurse -Force
    Remove-Item -LiteralPath $downloadPath -Force
} else {
    Copy-Item -LiteralPath $downloadPath -Destination (Join-Path $destination $fileName) -Force
    Remove-Item -LiteralPath $downloadPath -Force
}

Write-Host "Installed $Asset into $destination"
