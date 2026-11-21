$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$Root = $PSScriptRoot
$BinCpu = Join-Path $Root 'bin_cpu'
$BinCuda = Join-Path $Root 'bin_cuda'
$ModelsDir = Join-Path $Root 'models'
$UiPath = Join-Path $Root 'ui.html'
$LogPath = Join-Path $Root 'pslm.log'
$ConfigPath = Join-Path $Root 'models.json'
$ApiPort = 8091
$InferenceProcess = $null
$MovementLogPath = Join-Path $Root 'movements.jsonl'
$script:IsRecordingMovements = $false
$script:LastMovementPoint = $null
$script:MovementTimer = $null

foreach ($path in @($BinCpu, $BinCuda, $ModelsDir)) {
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
    [pscustomobject]@{
        HasNvidiaGpu = $gpu
        Profile = if ($gpu) { 'cuda' } else { 'cpu' }
    }
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

if ($engineInstalled -and $modelInstalled) {
    [void](Start-LocalServer $config $hardware.Profile)
}

$uiUrl = 'file://' + ($UiPath -replace '\\','/')
Start-Process $uiUrl

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
                })
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
                $completion = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/chat/completions' -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 120
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
