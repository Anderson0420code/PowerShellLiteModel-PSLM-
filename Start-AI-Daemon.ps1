$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$Root = $PSScriptRoot
$BinCpu = Join-Path $Root 'bin_cpu'
$BinCuda = Join-Path $Root 'bin_cuda'
$ModelsDir = Join-Path $Root 'models'
$KnowledgeDir = Join-Path $Root 'knowledge'
$RagDir = Join-Path $Root 'rag'
$UiPath = Join-Path $Root 'ui.html'
$LogPath = Join-Path $Root 'pslm.log'
$ConfigPath = Join-Path $Root 'models.json'
$ApiPort = 8091
$InferenceProcess = $null
$MovementLogPath = Join-Path $Root 'movements.jsonl'
$TerminalLogPath = Join-Path $Root 'terminal.jsonl'
$script:IsRecordingMovements = $false
$script:LastMovementPoint = $null
$script:MovementTimer = $null

foreach ($path in @($BinCpu, $BinCuda, $ModelsDir, $KnowledgeDir, $RagDir)) {
    if (-not (Test-Path $path)) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
}

function Write-PslmLog {
    param([string]$Message)
    Add-Content -LiteralPath $LogPath -Value ('[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8
}

Add-Type -ReferencedAssemblies (
    [System.Reflection.Assembly]::LoadWithPartialName('UIAutomationClient').Location,
    [System.Reflection.Assembly]::LoadWithPartialName('UIAutomationTypes').Location,
    [System.Reflection.Assembly]::LoadWithPartialName('WindowsBase').Location
) -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Automation;

public sealed class PslmNative {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int X, int Y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out PslmPoint point);

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
}

[StructLayout(LayoutKind.Sequential)]
public struct PslmPoint {
    public int X;
    public int Y;
}

public sealed class PslmControlItem {
    public string name;
    public string controlType;
    public int x;
    public int y;
    public int width;
    public int height;
}

public sealed class PslmAutomation {
    public static string Scan(int limit) {
        var root = AutomationElement.FromHandle(PslmNative.GetForegroundWindow());
        if (root == null) return "[]";
        var condition = new OrCondition(
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Button),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Edit),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ComboBox),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Document)
        );
        var elements = root.FindAll(TreeScope.Descendants, condition);
        var list = new List<PslmControlItem>();
        foreach (AutomationElement element in elements) {
            if (list.Count >= limit) break;
            try {
                var rect = element.Current.BoundingRectangle;
                if (rect.Width <= 0 || rect.Height <= 0) continue;
                list.Add(new PslmControlItem {
                    name = element.Current.Name,
                    controlType = element.Current.ControlType.ProgrammaticName,
                    x = (int)Math.Round(rect.Left),
                    y = (int)Math.Round(rect.Top),
                    width = (int)Math.Round(rect.Width),
                    height = (int)Math.Round(rect.Height)
                });
            } catch { }
        }
        return NewtonsoftLikeJson(list);
    }

    private static string Esc(string value) {
        if (value == null) return "";
        var b = new StringBuilder();
        foreach (char c in value) {
            if (c == '"' ) b.Append("\\\"");
            else if (c == '\\') b.Append("\\\\");
            else if (c == '\n') b.Append("\\n");
            else if (c == '\r') b.Append("\\r");
            else b.Append(c);
        }
        return b.ToString();
    }

    private static string NewtonsoftLikeJson(List<PslmControlItem> list) {
        var parts = new List<string>();
        foreach (PslmControlItem item in list) {
            parts.Add("{\"name\":\"" + Esc(item.name) + "\",\"controlType\":\"" + Esc(item.controlType) +
                "\",\"x\":" + item.x + ",\"y\":" + item.y +
                ",\"width\":" + item.width + ",\"height\":" + item.height + "}");
        }
        return "[" + string.Join(",", parts.ToArray()) + "]";
    }
}
'@

function Test-NvidiaGpu {
    $nvidiaSmi = Get-Command 'nvidia-smi.exe' -ErrorAction SilentlyContinue
    if (-not $nvidiaSmi) { return $false }
    try { & $nvidiaSmi.Source -q | Out-Null; return $LASTEXITCODE -eq 0 } catch { return $false }
}

function Get-HardwareProfile {
    $gpu = Test-NvidiaGpu
    $npuDevices = Get-CimInstance -ClassName Win32_PnPEntity -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -match '(NPU|Neural Processing|AI Boost|Versal|Neural Processor|Intel.*AI)'
        }
    $npuAvailable = [bool]($npuDevices | Select-Object -First 1)
    [pscustomobject]@{
        HasNvidiaGpu = $gpu
        HasNpu = $npuAvailable
        NpuNames = @($npuDevices | Where-Object Name | Select-Object -ExpandProperty Name -Unique)
        Profile = if ($gpu) { 'cuda' } elseif ($npuAvailable) { 'npu-hybrid' } else { 'cpu' }
    }
}

function Get-RagConfig($Config) {
    if ($Config.rag) { return $Config.rag }
    [pscustomobject]@{
        enabled=$true
        chunkCharacters=900
        chunkOverlap=120
        maxResults=5
        indexFile='rag/index.json'
        extensions=@('.txt','.md','.csv','.json','.log')
    }
}

function ConvertTo-RagChunks([string]$Text, [int]$ChunkSize, [int]$Overlap) {
    $normalized = ($Text -replace "`r`n?","`n").Trim()
    if (-not $normalized) { return @() }
    $chunks = New-Object System.Collections.Generic.List[object]
    $start = 0
    $id = 0
    while ($start -lt $normalized.Length) {
        $length = [Math]::Min($ChunkSize, $normalized.Length - $start)
        $chunkText = $normalized.Substring($start, $length).Trim()
        if ($chunkText) {
            $chunks.Add([pscustomobject]@{id=$id;text=$chunkText})
            $id++
        }
        $next = $start + $ChunkSize - $Overlap
        if ($next -le $start) { break }
        $start = $next
    }
    return $chunks.ToArray()
}

function Update-RagIndex($Config) {
    $rag = Get-RagConfig $Config
    $extensions = @($rag.extensions)
    $documents = New-Object System.Collections.Generic.List[object]
    $chunkSize = [Math]::Max(200,[int]$rag.chunkCharacters)
    $overlap = [Math]::Min([int]$rag.chunkOverlap,[Math]::Max(0,$chunkSize - 1))

    Get-ChildItem -LiteralPath $KnowledgeDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension.ToLowerInvariant() -in $extensions } |
        ForEach-Object {
            try {
                $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
                $relative = $_.FullName.Substring($KnowledgeDir.Length).TrimStart('\','/')
                foreach ($chunk in (ConvertTo-RagChunks $text $chunkSize $overlap)) {
                    $documents.Add([pscustomobject]@{
                        file=$relative
                        chunk=$chunk.id
                        text=$chunk.text
                    })
                }
            } catch {
                Write-PslmLog ('RAG index skipped ' + $_.FullName + ': ' + $_.Exception.Message)
            }
        }

    $indexPath = Join-Path $Root ([string]$rag.indexFile)
    New-Item -ItemType Directory -Path (Split-Path $indexPath -Parent) -Force | Out-Null
    [ordered]@{
        generatedAt=(Get-Date).ToUniversalTime().ToString('o')
        documentCount=$documents.Count
        chunks=@($documents.ToArray())
    } | ConvertTo-Json -Depth 8 -Compress | Set-Content -LiteralPath $indexPath -Encoding UTF8
    return $documents.Count
}

function Search-RagIndex($Config, [string]$Query, [int]$Limit) {
    $rag = Get-RagConfig $Config
    $indexPath = Join-Path $Root ([string]$rag.indexFile)
    if (-not (Test-Path -LiteralPath $indexPath -PathType Leaf)) { return @() }
    $index = Get-Content -LiteralPath $indexPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $queryTerms = ([regex]::Matches($Query.ToLowerInvariant(), '[\p{L}\p{N}_]+') | ForEach-Object Value |
        Where-Object { $_.Length -ge 2 } | Select-Object -Unique)
    if (-not $queryTerms -or -not $index.chunks) { return @() }

    $count = @($index.chunks).Count
    $docLengths = @($index.chunks | ForEach-Object { ([regex]::Matches($_.text.ToLowerInvariant(), '[\p{L}\p{N}_]+')).Count })
    $averageLength = if ($count) { ([double](($docLengths | Measure-Object -Sum).Sum)) / $count } else { 1 }
    $ranked = New-Object System.Collections.Generic.List[object]
    foreach ($chunk in $index.chunks) {
        $lower = $chunk.text.ToLowerInvariant()
        $length = ([regex]::Matches($lower, '[\p{L}\p{N}_]+')).Count
        $score = 0.0
        foreach ($term in $queryTerms) {
            $frequency = ([regex]::Matches($lower, [regex]::Escape($term))).Count
            if ($frequency -gt 0) {
                $idf = [Math]::Log((($count + 1.0) / 1.0) + 1.0)
                $normalized = $frequency * 2.2 / ($frequency + 1.2 * (0.25 + 0.75 * $length / [Math]::Max($averageLength,1.0)))
                $score += $idf * $normalized
            }
        }
        if ($score -gt 0) {
            $ranked.Add([pscustomobject]@{
                score=[Math]::Round($score,6)
                file=$chunk.file
                chunk=$chunk.chunk
                text=$chunk.text
            })
        }
    }
    return @($ranked | Sort-Object score -Descending | Select-Object -First $Limit)
}

function Get-Config {
    Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
}

function Test-InstalledEngine([string]$Profile) {
    $directory = if ($Profile -eq 'cuda') { $BinCuda } else { $BinCpu }
    [bool](Get-ChildItem -LiteralPath $directory -Filter 'llama-server.exe' -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Test-SelectedModel($Config, [string]$Profile) {
    $model = $Config.models | Where-Object { $_.profile -eq $Profile } | Select-Object -First 1
    if (-not $model) { return $false }
    Test-Path -LiteralPath (Join-Path $ModelsDir $model.file) -PathType Leaf
}

function Start-LocalServer($Config, [string]$Profile) {
    $directory = if ($Profile -eq 'cuda') { $BinCuda } else { $BinCpu }
    $server = Get-ChildItem -LiteralPath $directory -Filter 'llama-server.exe' -File -Recurse | Select-Object -First 1
    $model = $Config.models | Where-Object { $_.profile -eq $Profile } | Select-Object -First 1
    if (-not $server -or -not $model) { return $false }
    $modelPath = Join-Path $ModelsDir $model.file
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) { return $false }
    $arguments = '--host 127.0.0.1 --port 8080 --model "{0}"' -f $modelPath
    $arguments += if ($Profile -eq 'cuda') { ' --n-gpu-layers 999' } else { ' --n-gpu-layers 0' }
    $script:InferenceProcess = Start-Process -FilePath $server.FullName -ArgumentList $arguments -WorkingDirectory $server.DirectoryName -WindowStyle Hidden -PassThru
    Write-PslmLog "Started llama-server ($Profile)"
    return $true
}

function Test-EscapeHeld {
    return ([PslmNative]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0
}

function Show-HumanApproval([string]$Description, [int]$X, [int]$Y) {
    if (Test-EscapeHeld) { return 'abort' }

    [PslmNative]::SetCursorPos($X, $Y)
    $border = New-Object System.Windows.Forms.Form
    $border.FormBorderStyle = 'None'
    $border.StartPosition = 'Manual'
    $border.Bounds = [System.Drawing.Rectangle]::FromLTRB([Math]::Max(0,$X-100), [Math]::Max(0,$Y-50), $X+101, $Y+51)
    $border.TopMost = $true
    $border.BackColor = [System.Drawing.Color]::Red
    $border.Opacity = 0.45
    $border.ShowInTaskbar = $false
    $border.Show()

    $result = [System.Windows.Forms.MessageBox]::Show(
        $border,
        ('Controlled action:' + [Environment]::NewLine + [Environment]::NewLine + $Description + [Environment]::NewLine + [Environment]::NewLine + 'Approve only after review. Press ESC to abort.'),
        'PSLM Human Approval',
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Warning
    )
    $border.Close()
    if (Test-EscapeHeld) { return 'abort' }
    if ($result -eq [System.Windows.Forms.DialogResult]::Yes) { return 'approve' } else { return 'reject' }
}

function Invoke-ApprovedAction($Action) {
    if (-not $Action) { throw 'Missing action object' }
    $type = [string]$Action.type
    if ($type -notin @('preview','click','type','shortcut')) { throw 'Unsupported action type' }
    if ($type -eq 'preview') {
        $limit = if ($Action.limit) { [Math]::Min([int]$Action.limit, 100) } else { 50 }
        return [PslmAutomation]::Scan($limit)
    }

    $x = 0
    $y = 0
    if ($Action.x) { $x = [int]$Action.x }
    if ($Action.y) { $y = [int]$Action.y }
    if ($type -eq 'click') {
        $description = 'Mouse click at ({0},{1})' -f $x, $y
    } elseif ($type -eq 'type') {
        $description = ('Type text at ({0},{1}): ' -f $x, $y) + [string]$Action.text
    } else {
        $description = 'Send shortcut: ' + [string]$Action.keys
    }
    $decision = Show-HumanApproval $description $x $y
    if ($decision -ne 'approve') { return @{decision=$decision} | ConvertTo-Json -Compress }
    if (Test-EscapeHeld) { return @{decision='abort'} | ConvertTo-Json -Compress }

    [PslmNative]::SetCursorPos($x,$y)
    if ($type -eq 'click') {
        [PslmNative]::mouse_event([PslmNative]::MOUSEEVENTF_LEFTDOWN,0,0,0,[UIntPtr]::Zero)
        [PslmNative]::mouse_event([PslmNative]::MOUSEEVENTF_LEFTUP,0,0,0,[UIntPtr]::Zero)
    } elseif ($type -eq 'type') {
        [PslmNative]::mouse_event([PslmNative]::MOUSEEVENTF_LEFTDOWN,0,0,0,[UIntPtr]::Zero)
        [PslmNative]::mouse_event([PslmNative]::MOUSEEVENTF_LEFTUP,0,0,0,[UIntPtr]::Zero)
        [System.Windows.Forms.SendKeys]::SendWait([string]$Action.text)
    } elseif ($type -eq 'shortcut') {
        $allowed = @('^c','^v','^a','^l','%{F4}','{ESC}','^{HOME}','^{END}','{ENTER}','{TAB}')
        $key = [string]$Action.keys
        if ($key -notin $allowed) { throw 'Shortcut not allowlisted' }
        [System.Windows.Forms.SendKeys]::SendWait($key)
    }
    return @{decision='executed'} | ConvertTo-Json -Compress
}

function Send-JsonResponse($Context, [int]$StatusCode, $Payload) {
    $json = if ($Payload -is [string]) { $Payload } else { $Payload | ConvertTo-Json -Depth 8 -Compress }
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'application/json; charset=utf-8'
    $Context.Response.Headers.Add('Access-Control-Allow-Origin','*')
    $Context.Response.Headers.Add('Access-Control-Allow-Headers','Content-Type')
    $Context.Response.OutputStream.Write($bytes,0,$bytes.Length)
    $Context.Response.Close()
}

function Resolve-TerminalPath([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $Root }
    $candidate = [System.IO.Path]::GetFullPath((Join-Path $Root $RelativePath.Trim('"',' ','.')))
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    if ($candidate -ne $rootFull -and -not $candidate.StartsWith($rootFull + '\',[StringComparison]::OrdinalIgnoreCase)) {
        throw 'Terminal paths must remain inside the PSLM USB directory.'
    }
    return $candidate
}

function Write-TerminalLog([string]$Command, [string]$Output, [string]$Decision) {
    $record = [ordered]@{
        timestamp=(Get-Date).ToUniversalTime().ToString('o')
        command=$Command
        decision=$Decision
        output=$Output
    }
    Add-Content -LiteralPath $TerminalLogPath -Value ($record | ConvertTo-Json -Depth 5 -Compress) -Encoding UTF8
}

function Invoke-ReadOnlyTerminalCommand([string]$Command) {
    $trimmed = $Command.Trim()
    if ($trimmed -match '[;|&<>`]' -or $trimmed -match '\$\(') {
        throw 'Shell operators and command expansion are not permitted.'
    }
    if ($trimmed.Length -gt 2000) { throw 'Command is too long.' }

    if ($trimmed -in @('help','?')) {
        return @(
            'pwd / Get-Location'
            'ls [path] / dir [path] / Get-ChildItem [path]'
            'cat <path> / type <path> / Get-Content <path>'
            'git status'
            'git log'
            'git diff'
            'git add .'
            'git commit -m "<message>"'
            'git push'
            'history'
        ) -join "`n"
    }
    if ($trimmed -in @('history')) {
        if (-not (Test-Path -LiteralPath $TerminalLogPath -PathType Leaf)) { return 'No terminal history.' }
        return Get-Content -LiteralPath $TerminalLogPath -Tail 30 -Raw
    }
    if ($trimmed -in @('pwd','Get-Location')) { return $Root }

    if ($trimmed -match '^(ls|dir|Get-ChildItem)(?:\s+(.+))?$') {
        $relative = [string]$Matches[2]
        $path = Resolve-TerminalPath $relative
        if (-not (Test-Path -LiteralPath $path)) { throw "Path not found: $relative" }
        return Get-ChildItem -LiteralPath $path -Force | ForEach-Object {
            '{0}`t{1}`t{2:N0}' -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $_.Name, $_.Length
        } | Out-String
    }

    if ($trimmed -match '^(cat|type|Get-Content)\s+(.+)$') {
        $path = Resolve-TerminalPath ([string]$Matches[2])
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'File not found.' }
        return Get-Content -LiteralPath $path -Raw
    }

    if ($trimmed -eq 'git status') {
        $result = & git -C $Root --no-pager status --short --branch 2>&1
        return ($result | Out-String)
    }
    if ($trimmed -eq 'git log') {
        $result = & git -C $Root --no-pager log --oneline --decorate -10 2>&1
        return ($result | Out-String)
    }
    if ($trimmed -eq 'git diff') {
        $result = & git -C $Root --no-pager diff --stat; $result += & git -C $Root --no-pager diff --check
        return ($result | Out-String)
    }

    throw 'Command is not in the read-only terminal allowlist. Use help to list commands.'
}

function Invoke-TerminalPrompt([string]$Command) {
    $trimmed = $Command.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) { throw 'A command is required.' }

    $mutatingGit = $trimmed -match '^git (add \. |commit -m |commit -m$|push$)'
    $mutatingGit = $mutatingGit -and (
        $trimmed -eq 'git add .' -or
        $trimmed -match '^git commit -m "([^"]{1,200})"$' -or
        $trimmed -eq 'git push'
    )

    if (-not $mutatingGit) {
        $output = Invoke-ReadOnlyTerminalCommand $trimmed
        Write-TerminalLog $trimmed $output 'executed'
        return [pscustomobject]@{
            decision='executed'
            output=$output
            log=$TerminalLogPath
        }
    }

    $decision = Show-HumanApproval ('Terminal command: ' + $trimmed) 200 200
    if ($decision -ne 'approve') {
        Write-TerminalLog $trimmed '' $decision
        return [pscustomobject]@{decision=$decision;output='';log=$TerminalLogPath}
    }
    if (Test-EscapeHeld) {
        Write-TerminalLog $trimmed '' 'abort'
        return [pscustomobject]@{decision='abort';output='';log=$TerminalLogPath}
    }

    $result = if ($trimmed -eq 'git add .') {
        & git -C $Root add --all 2>&1
    } elseif ($trimmed -eq 'git push') {
        & git -C $Root push origin main 2>&1
    } elseif ($trimmed -match '^git commit -m "([^"]{1,200})"$') {
        $message = [string]$Matches[1]
        & git -C $Root -c user.name='Anderson0420code' -c user.email='223556219+Copilot@users.noreply.github.com' commit -m $message 2>&1
    }
    $output = ($result | Out-String)
    Write-TerminalLog $trimmed $output 'executed'
    return [pscustomobject]@{decision='executed';output=$output;log=$TerminalLogPath}
}

function Start-MovementRecording {
    $script:LastMovementPoint = $null
    $script:IsRecordingMovements = $true
    $header = [ordered]@{
        event='recording_started'
        timestamp=(Get-Date).ToUniversalTime().ToString('o')
    }
    Add-Content -LiteralPath $MovementLogPath -Value ($header | ConvertTo-Json -Compress) -Encoding UTF8

    $callback = [System.Threading.TimerCallback]{
        if (-not $script:IsRecordingMovements) { return }
        $point = [PslmPoint]::new()
        $pointRef = [ref]$point
        if (-not [PslmNative]::GetCursorPos($pointRef)) { return }
        if ($script:LastMovementPoint -and
            $script:LastMovementPoint.X -eq $point.X -and
            $script:LastMovementPoint.Y -eq $point.Y) { return }

        $script:LastMovementPoint = $point
        $record = [ordered]@{
            event='cursor_moved'
            timestamp=(Get-Date).ToUniversalTime().ToString('o')
            x=$point.X
            y=$point.Y
            escHeld=([PslmNative]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0
        }
        Add-Content -LiteralPath $MovementLogPath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
    }
    $script:MovementTimer = [System.Threading.Timer]::new($callback, $null, 0, 25)
}

function Stop-MovementRecording {
    if ($script:MovementTimer) {
        $script:MovementTimer.Dispose()
        $script:MovementTimer = $null
    }
    $script:IsRecordingMovements = $false
    $record = [ordered]@{
        event='recording_stopped'
        timestamp=(Get-Date).ToUniversalTime().ToString('o')
    }
    Add-Content -LiteralPath $MovementLogPath -Value ($record | ConvertTo-Json -Compress) -Encoding UTF8
}

$config = Get-Config
$hardware = Get-HardwareProfile
$engineInstalled = Test-InstalledEngine $hardware.Profile
$modelInstalled = Test-SelectedModel $config $hardware.Profile

if ($config.rag.enabled) {
    try {
        $ragChunkCount = Update-RagIndex $config
        Write-PslmLog ('RAG index ready: ' + $ragChunkCount + ' chunks')
    } catch {
        Write-PslmLog ('RAG index failed: ' + $_.Exception.Message)
    }
}

if ($engineInstalled -and $modelInstalled) {
    [void](Start-LocalServer $config $hardware.Profile)
}

$uiUrl = 'file://' + ($UiPath -replace '\\','/')
function Start-PslmAppWindow([string]$Url) {
    $browserCandidates = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "${env:LocalAppData}\Google\Chrome\Application\chrome.exe"
    )
    $browser = $browserCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $browser) {
        Write-PslmLog 'No Edge or Chrome executable found; opened the default browser instead'
        Start-Process $Url
        return
    }
    $arguments = @(
        "--app=$Url",
        '--lang=zh-TW',
        '--window-size=1280,800',
        '--disable-background-mode',
        '--new-window'
    )
    Start-Process -FilePath $browser -ArgumentList $arguments
    Write-PslmLog ('PSLM UI opened in app mode using ' + $browser)
}
Start-PslmAppWindow $uiUrl

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add(('http://127.0.0.1:{0}/' -f $ApiPort))
try {
    $listener.Start()
} catch {
    Write-PslmLog ('API listener failed: ' + $_.Exception.Message)
    throw
}
Write-PslmLog ('Daemon started with profile ' + $hardware.Profile)

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $path = $request.Url.AbsolutePath
        try {
            if ($request.HttpMethod -eq 'OPTIONS') {
                $context.Response.StatusCode = 204
                $context.Response.Headers.Add('Access-Control-Allow-Origin','*')
                $context.Response.Headers.Add('Access-Control-Allow-Headers','Content-Type')
                $context.Response.Headers.Add('Access-Control-Allow-Methods','GET,POST,OPTIONS')
                $context.Response.Close()
            } elseif ($path -eq '/status' -and $request.HttpMethod -eq 'GET') {
                $engineNow = Test-InstalledEngine $hardware.Profile
                $modelNow = Test-SelectedModel $config $hardware.Profile
                Send-JsonResponse $context 200 ([ordered]@{
                    profile=$hardware.Profile
                    engineInstalled=$engineNow
                    modelInstalled=$modelNow
                    automationRunning=$true
                    emergencyEsc=Test-EscapeHeld
                    recordingMovements=$script:IsRecordingMovements
                    movementLog=$MovementLogPath
                    npuAvailable=$hardware.HasNpu
                    npuNames=@($hardware.NpuNames)
                    ragEnabled=$([bool]$config.rag.enabled)
                    ragIndexExists=(Test-Path -LiteralPath (Join-Path $Root ([string]$config.rag.indexFile)) -PathType Leaf)
                    terminalLog=$TerminalLogPath
                })
            } elseif ($path -eq '/rag/index' -and $request.HttpMethod -eq 'POST') {
                $count = Update-RagIndex $config
                Send-JsonResponse $context 200 ([ordered]@{indexedChunks=$count;knowledgeDirectory=$KnowledgeDir})
            } elseif ($path -eq '/rag/search' -and $request.HttpMethod -eq 'POST') {
                $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Dispose()
                $limit = [Math]::Min([Math]::Max([int]$body.limit,1),20)
                $results = Search-RagIndex $config ([string]$body.query) $limit
                Send-JsonResponse $context 200 ([ordered]@{results=@($results)})
            } elseif ($path -eq '/terminal' -and $request.HttpMethod -eq 'POST') {
                $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Dispose()
                $result = Invoke-TerminalPrompt ([string]$body.command)
                Send-JsonResponse $context 200 $result
            } elseif ($path -eq '/recording' -and $request.HttpMethod -eq 'POST') {
                $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Dispose()
                if ([string]$body.action -eq 'start') {
                    if (-not $script:IsRecordingMovements) { Start-MovementRecording }
                    Send-JsonResponse $context 200 ([ordered]@{recording=$true;log=$MovementLogPath})
                } elseif ([string]$body.action -eq 'stop') {
                    if ($script:IsRecordingMovements) { Stop-MovementRecording }
                    Send-JsonResponse $context 200 ([ordered]@{recording=$false;log=$MovementLogPath})
                } else {
                    Send-JsonResponse $context 400 ([ordered]@{error='Action must be start or stop'})
                }
            } elseif ($path -eq '/action' -and $request.HttpMethod -eq 'POST') {
                $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $action = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Dispose()
                $result = Invoke-ApprovedAction $action
                Send-JsonResponse $context 200 $result
            } elseif ($path -eq '/search' -and $request.HttpMethod -eq 'POST') {
                $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd() | ConvertFrom-Json
                $reader.Dispose()
                $query = [uri]::EscapeDataString([string]$body.q)
                $searchUrl = 'https://html.duckduckgo.com/html/?q=' + $query
                $html = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 20
                $results = [regex]::Matches($html.Content,'result__a[^>]*>(?<title>[^<]+)',[Text.RegularExpressions.RegexOptions]::IgnoreCase) |
                    ForEach-Object { $_.Groups['title'].Value -replace '&amp;','&' } |
                    Select-Object -First 5
                Send-JsonResponse $context 200 ([ordered]@{results=@($results)})
            } elseif ($path -eq '/completion' -and $request.HttpMethod -eq 'POST') {
                $reader = New-Object IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd()
                $reader.Dispose()
                $completionPayload = $body | ConvertFrom-Json
                if ($config.rag.enabled -and $completionPayload.messages) {
                    $lastUser = @($completionPayload.messages | Where-Object { $_.role -eq 'user' } | Select-Object -Last 1)
                    if ($lastUser.Count -gt 0) {
                        $ragResults = Search-RagIndex $config ([string]$lastUser[0].content) ([int]$config.rag.maxResults)
                        if ($ragResults.Count -gt 0) {
                            $contextText = ($ragResults | ForEach-Object { "Source: $($_.file)#$($_.chunk)`n$($_.text)" }) -join "`n`n"
                            $systemMessage = [pscustomobject]@{
                                role='system'
                                content='Use the following local knowledge base context only as supporting evidence. Cite source file and chunk numbers. If context is insufficient, say so explicitly.' + "`n`n" + $contextText
                            }
                            $messages = New-Object System.Collections.Generic.List[object]
                            $messages.Add($systemMessage)
                            foreach ($message in $completionPayload.messages) { $messages.Add($message) }
                            $completionPayload.messages = $messages.ToArray()
                        }
                    }
                }
                $completionBody = $completionPayload | ConvertTo-Json -Depth 12 -Compress
                $completion = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $completionBody -TimeoutSec 120
                Send-JsonResponse $context 200 $completion
            } else {
                Send-JsonResponse $context 404 ([ordered]@{error='Not found'})
            }
        } catch {
            Write-PslmLog ('Request failed: ' + $_.Exception.Message)
            Send-JsonResponse $context 400 ([ordered]@{error=$_.Exception.Message})
        }
    }
} finally {
    if ($script:IsRecordingMovements) { Stop-MovementRecording }
    $listener.Stop()
    $listener.Close()
    if ($InferenceProcess -and -not $InferenceProcess.HasExited) { Stop-Process -Id $InferenceProcess.Id -Force }
}
