param(
  [string]$StateFile = '',
  [string]$PositionFile = ''
)

$ErrorActionPreference = 'Stop'

$baseDir = Join-Path $env:LOCALAPPDATA 'dsh-session-notifier'
if ([string]::IsNullOrWhiteSpace($StateFile)) {
  $StateFile = Join-Path $baseDir 'state.json'
}
if ([string]::IsNullOrWhiteSpace($PositionFile)) {
  $PositionFile = Join-Path $baseDir 'overlay-position.json'
}
$logPath = Join-Path $baseDir 'overlay.log'
$settingsPath = Join-Path $baseDir 'overlay-settings.json'

function Write-Log([string]$message) {
  try {
    if (-not (Test-Path -LiteralPath $baseDir)) {
      New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
    }
    $line = '[{0}] {1}{2}' -f (Get-Date).ToString('s'), $message, [Environment]::NewLine
    [System.IO.File]::AppendAllText($logPath, $line, [System.Text.Encoding]::UTF8)
  } catch {
  }
}

$mutex = $null
$ownsMutex = $false
try {
  $mutex = [System.Threading.Mutex]::new($false, 'Local\DshSessionNotifierOverlay')
  $ownsMutex = $mutex.WaitOne(0)
} catch {
  $ownsMutex = $false
}
if (-not $ownsMutex) {
  exit 0
}

try {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase
  Add-Type -AssemblyName System.Xaml
  Add-Type -AssemblyName System
  Add-Type -AssemblyName System.Drawing
  Add-Type -AssemblyName System.Windows.Forms

  Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class DshOverlayNative {
  [DllImport("user32.dll")]
  public static extern bool SetForegroundWindow(IntPtr hWnd);

  [DllImport("user32.dll")]
  public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}

public static class DshOverlayHitTest {
  private const int GWL_WNDPROC = -4;
  private const int WM_NCHITTEST = 0x84;
  private const int HTTRANSPARENT = -1;
  private const int HTCLIENT = 1;

  [StructLayout(LayoutKind.Sequential)]
  private struct POINT { public int X; public int Y; }

  [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
  private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

  [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
  private static extern IntPtr SetWindowLong32(IntPtr hWnd, int nIndex, IntPtr dwNewLong);

  [DllImport("user32.dll")]
  private static extern IntPtr CallWindowProc(IntPtr lpPrevWndFunc, IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

  [DllImport("user32.dll")]
  private static extern bool ScreenToClient(IntPtr hWnd, ref POINT lpPoint);

  [DllImport("user32.dll")]
  private static extern uint GetDpiForWindow(IntPtr hWnd);

  private delegate IntPtr WndProcDelegate(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

  private static IntPtr target = IntPtr.Zero;
  private static IntPtr oldProc = IntPtr.Zero;
  private static WndProcDelegate newProc;
  private static int petCx;
  private static int petCy;
  private static int petRx;
  private static int petRy;
  private static int[] badge = new int[4];
  private static int[] pill = new int[4];

  public static bool BadgeVisible;
  public static bool PillVisible;

  public static void Install(IntPtr hwnd, int cx, int cy, int rx, int ry, int bl, int bt, int br, int bb, int pl, int pt, int pr, int pb) {
    target = hwnd;
    petCx = cx;
    petCy = cy;
    petRx = rx;
    petRy = ry;
    badge = new int[] { bl, bt, br, bb };
    pill = new int[] { pl, pt, pr, pb };
    newProc = Hook;
    IntPtr pointer = Marshal.GetFunctionPointerForDelegate(newProc);
    if (IntPtr.Size == 8) {
      oldProc = SetWindowLongPtr(hwnd, GWL_WNDPROC, pointer);
    } else {
      oldProc = SetWindowLong32(hwnd, GWL_WNDPROC, pointer);
    }
  }

  public static void Uninstall() {
    if (target == IntPtr.Zero || oldProc == IntPtr.Zero) return;
    if (IntPtr.Size == 8) {
      SetWindowLongPtr(target, GWL_WNDPROC, oldProc);
    } else {
      SetWindowLong32(target, GWL_WNDPROC, oldProc);
    }
    target = IntPtr.Zero;
    oldProc = IntPtr.Zero;
    newProc = null;
  }

  private static bool InEllipse(double x, double y) {
    double dx = x - petCx;
    double dy = y - petCy;
    return ((dx * dx) / ((double)petRx * petRx)) + ((dy * dy) / ((double)petRy * petRy)) <= 1.0;
  }

  private static bool InRect(int[] rect, double x, double y) {
    return x >= rect[0] && x <= rect[2] && y >= rect[1] && y <= rect[3];
  }

  private static IntPtr Hook(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam) {
    if (msg == WM_NCHITTEST) {
      long value = lParam.ToInt64();
      int x = (int)value & 0xFFFF;
      if (x >= 0x8000) x -= 0x10000;
      int y = (int)((value >> 16) & 0xFFFF);
      if (y >= 0x8000) y -= 0x10000;
      POINT point = new POINT { X = x, Y = y };
      ScreenToClient(hwnd, ref point);
      double scale = 1.0;
      try {
        uint dpi = GetDpiForWindow(hwnd);
        if (dpi > 0) scale = dpi / 96.0;
      } catch {
      }
      double px = point.X / scale;
      double py = point.Y / scale;
      bool hit = InEllipse(px, py)
        || (BadgeVisible && InRect(badge, px, py))
        || (PillVisible && InRect(pill, px, py));
      return new IntPtr(hit ? HTCLIENT : HTTRANSPARENT);
    }
    return CallWindowProc(oldProc, hwnd, msg, wParam, lParam);
  }
}
"@

  function New-Brush([int]$r, [int]$g, [int]$b, [int]$a = 255) {
    $color = [System.Windows.Media.Color]::FromArgb($a, $r, $g, $b)
    return [System.Windows.Media.SolidColorBrush]::new($color)
  }

  function Get-Reason([string]$kind) {
    if ($kind -eq 'approval') { return 'Requiere aprobación' }
    if ($kind -eq 'planReview') { return 'Revisión de plan' }
    if ($kind -eq 'completed') { return 'Finalizada' }
    return 'Esperando respuesta'
  }

  function Get-CountText([int]$value) {
    if ($value -gt 99) { return '99+' }
    return [string]$value
  }

  function Get-EpochMilliseconds {
    $epoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
    return [long]([DateTime]::UtcNow - $epoch).TotalMilliseconds
  }

  function New-ChimeWav([double[]]$frequencies) {
    $sampleRate = 22050
    $duration = 0.42
    $sampleCount = [int]($sampleRate * $duration)
    $dataSize = $sampleCount * 2
    $stream = [System.IO.MemoryStream]::new()
    $writer = [System.IO.BinaryWriter]::new($stream)

    $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
    $writer.Write([int](36 + $dataSize))
    $writer.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
    $writer.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
    $writer.Write([int]16)
    $writer.Write([int16]1)
    $writer.Write([int16]1)
    $writer.Write([int]$sampleRate)
    $writer.Write([int]($sampleRate * 2))
    $writer.Write([int16]2)
    $writer.Write([int16]16)
    $writer.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
    $writer.Write([int]$dataSize)

    $noteStarts = @(0.0, 0.10)
    $noteDuration = 0.30
    for ($index = 0; $index -lt $sampleCount; $index++) {
      $time = $index / $sampleRate
      $sample = 0.0
      for ($note = 0; $note -lt $frequencies.Count; $note++) {
        $local = $time - $noteStarts[$note]
        if ($local -ge 0.0 -and $local -lt $noteDuration) {
          $envelope = [Math]::Exp(-7.0 * $local) * (1.0 - [Math]::Exp(-90.0 * $local))
          $sample += [Math]::Sin(2.0 * [Math]::PI * $frequencies[$note] * $local) * $envelope
        }
      }
      $value = [int]([Math]::Max(-1.0, [Math]::Min(1.0, $sample)) * 16000.0)
      $writer.Write([int16]$value)
    }

    $writer.Flush()
    $stream.Position = 0
    return $stream
  }

  function Load-OverlaySettings {
    $script:soundEnabled = $true
    try {
      if (Test-Path -LiteralPath $settingsPath) {
        $saved = Get-Content -LiteralPath $settingsPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($null -ne $saved.sound) {
          $script:soundEnabled = [bool]$saved.sound
        }
      }
    } catch {
    }
  }

  function Save-OverlaySettings {
    try {
      if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
      }
      $settings = [PSCustomObject]@{ sound = $script:soundEnabled }
      [System.IO.File]::WriteAllText($settingsPath, ($settings | ConvertTo-Json -Compress), [System.Text.Encoding]::UTF8)
    } catch {
    }
  }

  function Play-Sound([string]$kind) {
    if (-not $script:soundEnabled) { return }
    $now = $script:clock.Elapsed.TotalSeconds
    if (($now - $script:lastSoundAt) -lt 1.2) { return }
    $script:lastSoundAt = $now
    try {
      if ($kind -eq 'attention') {
        $script:attentionPlayer.Play()
      } else {
        $script:completedPlayer.Play()
      }
    } catch {
      Write-Log ('sound failed: ' + $_.Exception.Message)
    }
  }
  $script:soundEnabled = $true
  $script:lastSoundAt = -10.0
  $script:soundPrimed = $false
  $script:lastAttentionSignature = ''
  $script:lastCompletedCount = 0
  $script:lastRecentCompletion = $false
  $script:attentionPlayer = $null
  $script:completedPlayer = $null

  $script:clock = [System.Diagnostics.Stopwatch]::StartNew()
  $script:mode = 'stale'
  $script:modeStart = 0.0
  $script:state = $null
  $script:stale = $true
  $script:lastRunningCount = 0
  $script:recentCompletionUntil = 0.0
  $script:recentCompletion = $false
  $script:dragTotal = 0.0
  $script:dragging = $false
  $script:dragStartCursor = $null
  $script:dragStartLeft = 0.0
  $script:dragStartTop = 0.0
  $script:hwnd = [IntPtr]::Zero

  $script:brushes = @{
    idle = New-Brush 99 102 241
    running = New-Brush 59 130 246
    pending = New-Brush 245 158 11
    completed = New-Brush 16 185 129
    stale = New-Brush 148 163 184
    error = New-Brush 239 68 68
  }
  $script:darkPill = New-Brush 15 23 42 232
  $script:white = New-Brush 248 250 252
  $script:eyeWhite = New-Brush 248 250 252
  $script:eyeDark = New-Brush 30 27 75
  $script:fuchsia = New-Brush 240 171 252 110
  $script:gold = New-Brush 252 211 77
  $script:goldDark = New-Brush 180 83 9
  $script:black = New-Brush 15 23 42
  $script:transparent = [System.Windows.Media.Brushes]::Transparent

  Load-OverlaySettings
  try {
    $script:attentionPlayer = [System.Media.SoundPlayer]::new((New-ChimeWav -frequencies @(740.0, 988.0)))
    $script:attentionPlayer.Load()
    $script:completedPlayer = [System.Media.SoundPlayer]::new((New-ChimeWav -frequencies @(523.25, 783.99)))
    $script:completedPlayer.Load()
  } catch {
    Write-Log ('sound initialization failed: ' + $_.Exception.Message)
  }

  $script:window = [System.Windows.Window]::new()
  $script:window.WindowStyle = [System.Windows.WindowStyle]::None
  $script:window.AllowsTransparency = $true
  $script:window.Background = $script:transparent
  $script:window.Topmost = $true
  $script:window.ShowInTaskbar = $false
  $script:window.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $script:window.Width = 168
  $script:window.Height = 252
  $script:window.Title = 'DSH Session Notifier'
  $script:window.WindowStartupLocation = [System.Windows.WindowStartupLocation]::Manual

  function Move-Default {
    try {
      $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
      $script:window.Left = [double]($area.Right - $script:window.Width - 24)
      $script:window.Top = [double]($area.Bottom - $script:window.Height - 24)
    } catch {
      $script:window.Left = 80
      $script:window.Top = 80
    }
  }

  function Clamp-Window {
    try {
      $center = [System.Drawing.Point]::new(
        [int]($script:window.Left + ($script:window.Width / 2)),
        [int]($script:window.Top + ($script:window.Height / 2))
      )
      $screen = [System.Windows.Forms.Screen]::FromPoint($center)
      $area = $screen.WorkingArea
      $maxLeft = [double]($area.Right - $script:window.Width)
      $maxTop = [double]($area.Bottom - $script:window.Height)
      if ($script:window.Left -lt $area.Left) { $script:window.Left = [double]$area.Left }
      if ($script:window.Left -gt $maxLeft) { $script:window.Left = $maxLeft }
      if ($script:window.Top -lt $area.Top) { $script:window.Top = [double]$area.Top }
      if ($script:window.Top -gt $maxTop) { $script:window.Top = $maxTop }
    } catch {
    }
  }

  function Save-Position {
    try {
      if (-not (Test-Path -LiteralPath $baseDir)) {
        New-Item -ItemType Directory -Path $baseDir -Force | Out-Null
      }
      $position = [PSCustomObject]@{
        left = [Math]::Round($script:window.Left)
        top = [Math]::Round($script:window.Top)
      }
      [System.IO.File]::WriteAllText($PositionFile, ($position | ConvertTo-Json -Compress), [System.Text.Encoding]::UTF8)
    } catch {
    }
  }

  Move-Default
  if (Test-Path -LiteralPath $PositionFile) {
    try {
      $saved = Get-Content -LiteralPath $PositionFile -Raw -ErrorAction Stop | ConvertFrom-Json
      if ($null -ne $saved.left -and $null -ne $saved.top) {
        $script:window.Left = [double]$saved.left
        $script:window.Top = [double]$saved.top
      }
    } catch {
    }
  }
  Clamp-Window

  function Focus-Dsh {
    try {
      $process = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
          $_.MainWindowHandle -ne [IntPtr]::Zero -and
          ($_.ProcessName -like '*DeepSeek*' -or $_.MainWindowTitle -like '*DeepSeek*')
        } |
        Select-Object -First 1
      if ($null -ne $process) {
        [DshOverlayNative]::ShowWindow($process.MainWindowHandle, 9) | Out-Null
        [DshOverlayNative]::SetForegroundWindow($process.MainWindowHandle) | Out-Null
      }
    } catch {
      Write-Log ('Focus-Dsh failed: ' + $_.Exception.Message)
    }
  }

  function Get-DpiScale {
    try {
      $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($script:window)
      return @([double]$dpi.DpiScaleX, [double]$dpi.DpiScaleY)
    } catch {
      return @(1.0, 1.0)
    }
  }

  $script:canvas = [System.Windows.Controls.Canvas]::new()
  $script:canvas.Width = 168
  $script:canvas.Height = 216
  $script:canvas.Background = $script:transparent
  $script:canvas.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $script:canvas.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
  $script:canvas.RenderTransform = [System.Windows.Media.TranslateTransform]::new(0, 36)

  $script:aura = [System.Windows.Shapes.Ellipse]::new()
  $script:aura.Width = 132
  $script:aura.Height = 140
  $script:aura.Fill = $script:brushes.stale
  $script:aura.Opacity = 0.12
  $script:aura.IsHitTestVisible = $false
  $auraBlur = [System.Windows.Media.Effects.BlurEffect]::new()
  $auraBlur.Radius = 24
  $script:aura.Effect = $auraBlur
  [System.Windows.Controls.Canvas]::SetLeft($script:aura, 18)
  [System.Windows.Controls.Canvas]::SetTop($script:aura, 26)
  $script:canvas.Children.Add($script:aura) | Out-Null

  $script:shadow = [System.Windows.Shapes.Ellipse]::new()
  $script:shadow.Width = 68
  $script:shadow.Height = 14
  $script:shadow.Fill = $script:black
  $script:shadow.Opacity = 0.18
  $script:shadow.IsHitTestVisible = $false
  $shadowBlur = [System.Windows.Media.Effects.BlurEffect]::new()
  $shadowBlur.Radius = 6
  $script:shadow.Effect = $shadowBlur
  $script:shadowScale = [System.Windows.Media.ScaleTransform]::new(1, 1, 34, 7)
  $script:shadow.RenderTransform = $script:shadowScale
  [System.Windows.Controls.Canvas]::SetLeft($script:shadow, 50)
  [System.Windows.Controls.Canvas]::SetTop($script:shadow, 172)
  $script:canvas.Children.Add($script:shadow) | Out-Null

  $script:pet = [System.Windows.Controls.Canvas]::new()
  $script:pet.Width = 168
  $script:pet.Height = 170
  $script:pet.Background = $script:transparent
  $script:pet.IsHitTestVisible = $false
  $script:petMove = [System.Windows.Media.TranslateTransform]::new()
  $script:petRotate = [System.Windows.Media.RotateTransform]::new(0, 84, 96)
  $script:petScale = [System.Windows.Media.ScaleTransform]::new(1, 1, 84, 96)
  $petGroup = [System.Windows.Media.TransformGroup]::new()
  $petGroup.Children.Add($script:petMove) | Out-Null
  $petGroup.Children.Add($script:petRotate) | Out-Null
  $petGroup.Children.Add($script:petScale) | Out-Null
  $script:pet.RenderTransform = $petGroup
  $script:canvas.Children.Add($script:pet) | Out-Null

  function Load-GengarFrameSet([string]$name) {
    $frames = @()
    try {
      $folder = Join-Path $PSScriptRoot ('frames\' + $name)
      if (-not (Test-Path -LiteralPath $folder)) { return $frames }
      foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter 'frame-*.png' | Sort-Object Name)) {
        try {
          $bitmap = [System.Windows.Media.Imaging.BitmapImage]::new()
          $bitmap.BeginInit()
          $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
          $bitmap.UriSource = [Uri]::new($file.FullName)
          $bitmap.EndInit()
          $bitmap.Freeze()
          $frames += $bitmap
        } catch {
          Write-Log ('frame load failed: ' + $file.FullName + ' ' + $_.Exception.Message)
        }
      }
    } catch {
      Write-Log ('frame set load failed: ' + $name + ' ' + $_.Exception.Message)
    }
    return $frames
  }

  $script:gengarFrames = @{
    idle = @()
    thinking = @()
    commands = @()
    searching = @()
    writing = @()
    approval = @()
    excited = @()
    happy = @()
    sad = @()
    sleeping = @()
  }
  foreach ($frameSetName in @('idle', 'thinking', 'commands', 'searching', 'writing', 'approval', 'excited', 'happy', 'sad', 'sleeping')) {
    $script:gengarFrames[$frameSetName] = Load-GengarFrameSet $frameSetName
  }
  $script:useGengarFrames = ($script:gengarFrames.idle.Count -gt 0)
  $script:animationState = 'idle'
  $script:activityKind = ''
  $script:activityTool = ''
  $script:isError = $false
  $script:lastGengarFrame = -1
  $script:gengarSetName = ''

  $script:gengarImage = [System.Windows.Controls.Image]::new()
  $script:gengarImage.Width = 150
  $script:gengarImage.Height = 162
  $script:gengarImage.Stretch = [System.Windows.Media.Stretch]::Uniform
  $script:gengarImage.IsHitTestVisible = $false
  $script:gengarImage.Visibility = [System.Windows.Visibility]::Collapsed
  $script:gengarMove = [System.Windows.Media.TranslateTransform]::new()
  $script:gengarScale = [System.Windows.Media.ScaleTransform]::new(1, 1, 75, 81)
  $script:gengarRotate = [System.Windows.Media.RotateTransform]::new(0, 75, 81)
  $gengarGroup = [System.Windows.Media.TransformGroup]::new()
  $gengarGroup.Children.Add($script:gengarMove) | Out-Null
  $gengarGroup.Children.Add($script:gengarRotate) | Out-Null
  $gengarGroup.Children.Add($script:gengarScale) | Out-Null
  $script:gengarImage.RenderTransform = $gengarGroup
  [System.Windows.Controls.Canvas]::SetLeft($script:gengarImage, 9)
  [System.Windows.Controls.Canvas]::SetTop($script:gengarImage, 16)
  $script:canvas.Children.Add($script:gengarImage) | Out-Null
  if ($script:useGengarFrames) {
    $script:pet.Visibility = [System.Windows.Visibility]::Collapsed
    $script:gengarImage.Visibility = [System.Windows.Visibility]::Visible
    $script:gengarImage.Source = $script:gengarFrames.idle[0]
  }

  $bodyGradient = [System.Windows.Media.LinearGradientBrush]::new()
  $bodyGradient.StartPoint = [System.Windows.Point]::new(0.1, 0.1)
  $bodyGradient.EndPoint = [System.Windows.Point]::new(0.9, 0.95)
  $bodyGradient.GradientStops.Add([System.Windows.Media.GradientStop]::new(
    [System.Windows.Media.Color]::FromRgb(196, 181, 253), 0.0
  ))
  $bodyGradient.GradientStops.Add([System.Windows.Media.GradientStop]::new(
    [System.Windows.Media.Color]::FromRgb(91, 33, 182), 1.0
  ))

  $body = [System.Windows.Shapes.Path]::new()
  $body.Data = [System.Windows.Media.Geometry]::Parse(
    'M 84,44 C 60,44 44,62 44,88 L 44,116 C 50,110 56,120 62,114 C 68,108 74,120 80,114 C 86,108 92,120 98,114 C 104,108 110,120 116,114 C 122,108 124,112 124,116 L 124,88 C 124,62 108,44 84,44 Z'
  )
  $body.Fill = $bodyGradient
  $body.Stroke = $script:eyeDark
  $body.StrokeThickness = 2
  $body.StrokeLineJoin = [System.Windows.Media.PenLineJoin]::Round
  $body.IsHitTestVisible = $false
  $script:pet.Children.Add($body) | Out-Null

  $leftTuft = [System.Windows.Shapes.Path]::new()
  $leftTuft.Data = [System.Windows.Media.Geometry]::Parse('M 66,50 C 64,34 56,30 54,44 C 58,42 62,46 66,50 Z')
  $leftTuft.Fill = $bodyGradient
  $leftTuft.Stroke = $script:eyeDark
  $leftTuft.StrokeThickness = 1.5
  $leftTuft.IsHitTestVisible = $false
  $script:pet.Children.Add($leftTuft) | Out-Null

  $rightTuft = [System.Windows.Shapes.Path]::new()
  $rightTuft.Data = [System.Windows.Media.Geometry]::Parse('M 102,50 C 104,34 112,30 114,44 C 110,42 106,46 102,50 Z')
  $rightTuft.Fill = $bodyGradient
  $rightTuft.Stroke = $script:eyeDark
  $rightTuft.StrokeThickness = 1.5
  $rightTuft.IsHitTestVisible = $false
  $script:pet.Children.Add($rightTuft) | Out-Null

  $belly = [System.Windows.Shapes.Ellipse]::new()
  $belly.Width = 34
  $belly.Height = 28
  $belly.Fill = [System.Windows.Media.SolidColorBrush]::new([System.Windows.Media.Color]::FromArgb(60, 221, 214, 254))
  $belly.IsHitTestVisible = $false
  [System.Windows.Controls.Canvas]::SetLeft($belly, 67)
  [System.Windows.Controls.Canvas]::SetTop($belly, 90)
  $script:pet.Children.Add($belly) | Out-Null

  $leftArm = [System.Windows.Shapes.Path]::new()
  $leftArm.Data = [System.Windows.Media.Geometry]::Parse('M 46,92 C 30,90 20,102 24,116 C 32,118 40,108 46,100 Z')
  $leftArm.Fill = $bodyGradient
  $leftArm.Stroke = $script:eyeDark
  $leftArm.StrokeThickness = 1.8
  $leftArm.IsHitTestVisible = $false
  $script:leftArmRotate = [System.Windows.Media.RotateTransform]::new(0, 46, 96)
  $leftArm.RenderTransform = $script:leftArmRotate
  $script:pet.Children.Add($leftArm) | Out-Null

  $rightArm = [System.Windows.Shapes.Path]::new()
  $rightArm.Data = [System.Windows.Media.Geometry]::Parse('M 122,92 C 138,90 148,102 144,116 C 136,118 128,108 122,100 Z')
  $rightArm.Fill = $bodyGradient
  $rightArm.Stroke = $script:eyeDark
  $rightArm.StrokeThickness = 1.8
  $rightArm.IsHitTestVisible = $false
  $script:rightArmRotate = [System.Windows.Media.RotateTransform]::new(0, 122, 96)
  $rightArm.RenderTransform = $script:rightArmRotate
  $script:pet.Children.Add($rightArm) | Out-Null

  $script:eyes = [System.Windows.Controls.Canvas]::new()
  $script:eyes.Width = 168
  $script:eyes.Height = 160
  $script:eyes.Background = $script:transparent
  $script:eyes.IsHitTestVisible = $false
  $script:eyeScale = [System.Windows.Media.ScaleTransform]::new(1, 1, 84, 88)
  $script:eyes.RenderTransform = $script:eyeScale
  $script:pet.Children.Add($script:eyes) | Out-Null

  $leftEye = [System.Windows.Shapes.Ellipse]::new()
  $leftEye.Width = 16
  $leftEye.Height = 20
  $leftEye.Fill = $script:eyeWhite
  $leftEye.IsHitTestVisible = $false
  [System.Windows.Controls.Canvas]::SetLeft($leftEye, 64)
  [System.Windows.Controls.Canvas]::SetTop($leftEye, 78)
  $script:eyes.Children.Add($leftEye) | Out-Null

  $rightEye = [System.Windows.Shapes.Ellipse]::new()
  $rightEye.Width = 16
  $rightEye.Height = 20
  $rightEye.Fill = $script:eyeWhite
  $rightEye.IsHitTestVisible = $false
  [System.Windows.Controls.Canvas]::SetLeft($rightEye, 92)
  [System.Windows.Controls.Canvas]::SetTop($rightEye, 78)
  $script:eyes.Children.Add($rightEye) | Out-Null

  $leftPupil = [System.Windows.Shapes.Ellipse]::new()
  $leftPupil.Width = 8
  $leftPupil.Height = 11
  $leftPupil.Fill = $script:eyeDark
  $leftPupil.IsHitTestVisible = $false
  [System.Windows.Controls.Canvas]::SetLeft($leftPupil, 68)
  [System.Windows.Controls.Canvas]::SetTop($leftPupil, 82)
  $script:eyes.Children.Add($leftPupil) | Out-Null

  $rightPupil = [System.Windows.Shapes.Ellipse]::new()
  $rightPupil.Width = 8
  $rightPupil.Height = 11
  $rightPupil.Fill = $script:eyeDark
  $rightPupil.IsHitTestVisible = $false
  [System.Windows.Controls.Canvas]::SetLeft($rightPupil, 96)
  [System.Windows.Controls.Canvas]::SetTop($rightPupil, 82)
  $script:eyes.Children.Add($rightPupil) | Out-Null

  foreach ($highlightLeft in @(69, 97)) {
    $highlight = [System.Windows.Shapes.Ellipse]::new()
    $highlight.Width = 3
    $highlight.Height = 4
    $highlight.Fill = $script:white
    $highlight.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($highlight, $highlightLeft)
    [System.Windows.Controls.Canvas]::SetTop($highlight, 83)
    $script:eyes.Children.Add($highlight) | Out-Null
  }

  $mouth = [System.Windows.Shapes.Path]::new()
  $mouth.Data = [System.Windows.Media.Geometry]::Parse('M 70,110 Q 84,120 98,110')
  $mouth.Stroke = $script:eyeDark
  $mouth.StrokeThickness = 2.5
  $mouth.StrokeStartLineCap = [System.Windows.Media.PenLineCap]::Round
  $mouth.StrokeEndLineCap = [System.Windows.Media.PenLineCap]::Round
  $mouth.IsHitTestVisible = $false
  $script:pet.Children.Add($mouth) | Out-Null

  $leftFang = [System.Windows.Shapes.Path]::new()
  $leftFang.Data = [System.Windows.Media.Geometry]::Parse('M 74,110 L 79,110 L 76.5,116 Z')
  $leftFang.Fill = $script:white
  $leftFang.IsHitTestVisible = $false
  $script:pet.Children.Add($leftFang) | Out-Null

  $rightFang = [System.Windows.Shapes.Path]::new()
  $rightFang.Data = [System.Windows.Media.Geometry]::Parse('M 89,110 L 94,110 L 91.5,116 Z')
  $rightFang.Fill = $script:white
  $rightFang.IsHitTestVisible = $false
  $script:pet.Children.Add($rightFang) | Out-Null

  foreach ($cheekLeft in @(54, 104)) {
    $cheek = [System.Windows.Shapes.Ellipse]::new()
    $cheek.Width = 10
    $cheek.Height = 6
    $cheek.Fill = $script:fuchsia
    $cheek.IsHitTestVisible = $false
    [System.Windows.Controls.Canvas]::SetLeft($cheek, $cheekLeft)
    [System.Windows.Controls.Canvas]::SetTop($cheek, 104)
    $script:pet.Children.Add($cheek) | Out-Null
  }

  $bell = [System.Windows.Shapes.Path]::new()
  $bell.Data = [System.Windows.Media.Geometry]::Parse('M 84,126 C 78,126 74,131 74,136 L 74,141 L 94,141 L 94,136 C 94,131 90,126 84,126 Z')
  $bell.Fill = $script:gold
  $bell.Stroke = $script:goldDark
  $bell.StrokeThickness = 1.2
  $bell.IsHitTestVisible = $false
  $script:pet.Children.Add($bell) | Out-Null

  $bellClapper = [System.Windows.Shapes.Ellipse]::new()
  $bellClapper.Width = 5
  $bellClapper.Height = 5
  $bellClapper.Fill = $script:goldDark
  $bellClapper.IsHitTestVisible = $false
  [System.Windows.Controls.Canvas]::SetLeft($bellClapper, 81.5)
  [System.Windows.Controls.Canvas]::SetTop($bellClapper, 143)
  $script:pet.Children.Add($bellClapper) | Out-Null

  $script:sparkles = @()
  $sparkleGeometry = [System.Windows.Media.Geometry]::Parse(
    'M 0,-9 L 2.5,-2.5 L 9,0 L 2.5,2.5 L 0,9 L -2.5,2.5 L -9,0 L -2.5,-2.5 Z'
  )
  $sparklePositions = @(
    @{ left = 28; top = 62; phase = 0.0 },
    @{ left = 126; top = 74; phase = 0.7 },
    @{ left = 124; top = 150; phase = 1.4 }
  )
  foreach ($position in $sparklePositions) {
    $sparkle = [System.Windows.Shapes.Path]::new()
    $sparkle.Data = $sparkleGeometry
    $sparkle.Fill = $script:gold
    $sparkle.Opacity = 0
    $sparkle.Visibility = [System.Windows.Visibility]::Collapsed
    $sparkle.IsHitTestVisible = $false
    $scale = [System.Windows.Media.ScaleTransform]::new(1, 1, 0, 0)
    $sparkle.RenderTransform = $scale
    [System.Windows.Controls.Canvas]::SetLeft($sparkle, $position.left)
    [System.Windows.Controls.Canvas]::SetTop($sparkle, $position.top)
    $script:canvas.Children.Add($sparkle) | Out-Null
    $script:sparkles += [PSCustomObject]@{
      Shape = $sparkle
      Scale = $scale
      Phase = $position.phase
    }
  }

  $script:badge = [System.Windows.Controls.Border]::new()
  $script:badge.Width = 26
  $script:badge.Height = 26
  $script:badge.CornerRadius = [System.Windows.CornerRadius]::new(13)
  $script:badge.Background = $script:brushes.pending
  $script:badge.BorderBrush = $script:white
  $script:badge.BorderThickness = [System.Windows.Thickness]::new(2)
  $script:badge.Visibility = [System.Windows.Visibility]::Collapsed
  $script:badge.IsHitTestVisible = $false
  $script:badgeLabel = [System.Windows.Controls.TextBlock]::new()
  $script:badgeLabel.Foreground = $script:white
  $script:badgeLabel.FontSize = 11
  $script:badgeLabel.FontWeight = [System.Windows.FontWeights]::Bold
  $script:badgeLabel.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Center
  $script:badgeLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $script:badgeLabel.TextAlignment = [System.Windows.TextAlignment]::Center
  $script:badge.Child = $script:badgeLabel
  [System.Windows.Controls.Canvas]::SetLeft($script:badge, 118)
  [System.Windows.Controls.Canvas]::SetTop($script:badge, 28)
  $script:canvas.Children.Add($script:badge) | Out-Null

  $script:pill = [System.Windows.Controls.Border]::new()
  $script:pill.Width = 158
  $script:pill.Height = 24
  $script:pill.CornerRadius = [System.Windows.CornerRadius]::new(12)
  $script:pill.Background = $script:darkPill
  $script:pill.BorderBrush = $script:brushes.pending
  $script:pill.BorderThickness = [System.Windows.Thickness]::new(1)
  $script:pill.Visibility = [System.Windows.Visibility]::Collapsed
  $script:pill.IsHitTestVisible = $false
  $script:pillLabel = [System.Windows.Controls.TextBlock]::new()
  $script:pillLabel.Foreground = $script:white
  $script:pillLabel.FontSize = 10.5
  $script:pillLabel.FontWeight = [System.Windows.FontWeights]::SemiBold
  $script:pillLabel.TextAlignment = [System.Windows.TextAlignment]::Center
  $script:pillLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $script:pillLabel.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $script:pillLabel.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
  $script:pill.Child = $script:pillLabel
  [System.Windows.Controls.Canvas]::SetLeft($script:pill, 5)
  [System.Windows.Controls.Canvas]::SetTop($script:pill, 186)
  $script:canvas.Children.Add($script:pill) | Out-Null

  $script:toolTip = [System.Windows.Controls.ToolTip]::new()
  $script:toolTip.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Top
  $script:toolTipText = [System.Windows.Controls.TextBlock]::new()
  $script:toolTipText.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $script:toolTipText.MaxWidth = 380
  $script:toolTipText.FontSize = 12
  $script:toolTip.Content = $script:toolTipText
  $script:toolTipText.Text = 'Esperando estado de DeepSeek Harness.'

  $script:thumb = [System.Windows.Controls.Border]::new()
  $script:thumb.Width = 168
  $script:thumb.Height = 252
  $script:thumb.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $script:thumb.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
  $script:thumb.Background = $script:transparent
  $script:thumb.BorderThickness = [System.Windows.Thickness]::new(0)
  $script:thumb.Cursor = [System.Windows.Input.Cursors]::Hand
  $script:thumb.ToolTip = $script:toolTip
  [System.Windows.Controls.ToolTipService]::SetShowDuration($script:thumb, 30000)
  [System.Windows.Controls.ToolTipService]::SetInitialShowDelay($script:thumb, 350)

  $script:root = [System.Windows.Controls.Grid]::new()
  $script:root.Width = 168
  $script:root.Height = 252
  $script:root.Background = $script:transparent
  $script:root.Children.Add($script:canvas) | Out-Null
  $script:root.Children.Add($script:thumb) | Out-Null

  $script:bubbleLayer = [System.Windows.Controls.Canvas]::new()
  $script:bubbleLayer.Width = 168
  $script:bubbleLayer.Height = 42
  $script:bubbleLayer.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Left
  $script:bubbleLayer.VerticalAlignment = [System.Windows.VerticalAlignment]::Top
  $script:bubbleLayer.IsHitTestVisible = $false
  $script:bubble = [System.Windows.Controls.Border]::new()
  $script:bubble.Width = 156
  $script:bubble.Height = 30
  $script:bubble.CornerRadius = [System.Windows.CornerRadius]::new(15)
  $script:bubble.Background = $script:darkPill
  $script:bubble.BorderBrush = $script:brushes.idle
  $script:bubble.BorderThickness = [System.Windows.Thickness]::new(1)
  $script:bubble.IsHitTestVisible = $false
  $script:bubbleLabel = [System.Windows.Controls.TextBlock]::new()
  $script:bubbleLabel.Foreground = $script:white
  $script:bubbleLabel.FontSize = 10.5
  $script:bubbleLabel.FontWeight = [System.Windows.FontWeights]::SemiBold
  $script:bubbleLabel.TextAlignment = [System.Windows.TextAlignment]::Center
  $script:bubbleLabel.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
  $script:bubbleLabel.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
  $script:bubbleLabel.Margin = [System.Windows.Thickness]::new(8, 0, 8, 0)
  $script:bubbleLabel.Text = 'Vigilando...'
  $script:bubble.Child = $script:bubbleLabel
  [System.Windows.Controls.Canvas]::SetLeft($script:bubble, 6)
  [System.Windows.Controls.Canvas]::SetTop($script:bubble, 2)
  $script:bubbleLayer.Children.Add($script:bubble) | Out-Null
  $bubbleTail = [System.Windows.Shapes.Path]::new()
  $bubbleTail.Data = [System.Windows.Media.Geometry]::Parse('M 78,30 L 90,30 L 84,38 Z')
  $bubbleTail.Fill = $script:darkPill
  $bubbleTail.IsHitTestVisible = $false
  $script:bubbleLayer.Children.Add($bubbleTail) | Out-Null
  $script:root.Children.Add($script:bubbleLayer) | Out-Null
  $script:window.Content = $script:root

  $contextMenu = [System.Windows.Controls.ContextMenu]::new()

  $openItem = [System.Windows.Controls.MenuItem]::new()
  $openItem.Header = 'Abrir DeepSeek Harness'
  $openItem.Add_Click({ Focus-Dsh })
  $contextMenu.Items.Add($openItem) | Out-Null

  $topmostItem = [System.Windows.Controls.MenuItem]::new()
  $topmostItem.Header = 'Siempre visible'
  $topmostItem.IsCheckable = $true
  $topmostItem.IsChecked = $true
  $topmostItem.Add_Click({
    $script:window.Topmost = $topmostItem.IsChecked
  })
  $contextMenu.Items.Add($topmostItem) | Out-Null

  $soundItem = [System.Windows.Controls.MenuItem]::new()
  $soundItem.Header = 'Sonido'
  $soundItem.IsCheckable = $true
  $soundItem.IsChecked = $script:soundEnabled
  $soundItem.Add_Click({
    $script:soundEnabled = $soundItem.IsChecked
    Save-OverlaySettings
    if ($script:soundEnabled) {
      Play-Sound 'completed'
    }
  })
  $contextMenu.Items.Add($soundItem) | Out-Null

  $positionItem = [System.Windows.Controls.MenuItem]::new()
  $positionItem.Header = 'Reiniciar posición'
  $positionItem.Add_Click({
    Move-Default
    Save-Position
  })
  $contextMenu.Items.Add($positionItem) | Out-Null

  $contextMenu.Items.Add([System.Windows.Controls.Separator]::new()) | Out-Null

  $exitItem = [System.Windows.Controls.MenuItem]::new()
  $exitItem.Header = 'Salir'
  $exitItem.Add_Click({ $script:window.Close() })
  $contextMenu.Items.Add($exitItem) | Out-Null

  $script:thumb.ContextMenu = $contextMenu

  $script:thumb.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    $script:dragging = $true
    $script:dragTotal = 0.0
    $script:dragStartCursor = [System.Windows.Forms.Cursor]::Position
    $script:dragStartLeft = $script:window.Left
    $script:dragStartTop = $script:window.Top
    [void]$script:thumb.CaptureMouse()
    $eventArgs.Handled = $true
  })

  $script:thumb.Add_MouseMove({
    param($sender, $eventArgs)
    if (-not $script:dragging) { return }
    $cursor = [System.Windows.Forms.Cursor]::Position
    $dpi = Get-DpiScale
    $dx = ($cursor.X - $script:dragStartCursor.X) / $dpi[0]
    $dy = ($cursor.Y - $script:dragStartCursor.Y) / $dpi[1]
    $script:dragTotal = [Math]::Abs($dx) + [Math]::Abs($dy)
    $script:window.Left = $script:dragStartLeft + $dx
    $script:window.Top = $script:dragStartTop + $dy
    Clamp-Window
    $eventArgs.Handled = $true
  })

  $script:thumb.Add_MouseLeftButtonUp({
    param($sender, $eventArgs)
    if (-not $script:dragging) { return }
    $script:dragging = $false
    [void]$script:thumb.ReleaseMouseCapture()
    if ($script:dragTotal -lt 4.0) {
      Focus-Dsh
    }
    Clamp-Window
    Save-Position
    $eventArgs.Handled = $true
  })

  $script:window.Add_SourceInitialized({
    try {
      $helper = [System.Windows.Interop.WindowInteropHelper]::new($script:window)
      $script:hwnd = $helper.Handle
      [DshOverlayHitTest]::Install(
        $script:hwnd,
        84, 133, 70, 80,
        112, 60, 148, 96,
        4, 220, 164, 248
      )
    } catch {
      Write-Log ('SourceInitialized failed: ' + $_.Exception.Message)
    }
  })

  $script:window.Add_Closing({
    Save-Position
    try { [DshOverlayHitTest]::Uninstall() } catch {}
    try { if ($null -ne $script:stateTimer) { $script:stateTimer.Stop() } } catch {}
    try { if ($null -ne $script:animTimer) { $script:animTimer.Stop() } } catch {}
  })

  function Read-State {
    $now = Get-EpochMilliseconds
    try {
      $raw = [System.IO.File]::ReadAllText($StateFile, [System.Text.Encoding]::UTF8)
      $parsed = $raw | ConvertFrom-Json
      $script:state = $parsed
      $updated = 0.0
      try { $updated = [double]$parsed.updatedAt } catch { $updated = 0.0 }
      $script:stale = (($now - $updated) -gt 30000)
    } catch {
      $script:state = $null
      $script:stale = $true
    }
  }

  function Update-Ui {
    $state = $script:state
    $pending = 0
    $completed = 0
    $running = 0
    $alerts = @()
    $script:activityKind = ''
    $script:activityTool = ''
    $script:isError = $false
    if ($null -ne $state) {
      try { $pending = [int]$state.pendingCount } catch { $pending = 0 }
      try { $completed = [int]$state.completedCount } catch { $completed = 0 }
      try { $running = [int]$state.runningCount } catch { $running = 0 }
      try { $script:activityKind = [string]$state.activity } catch { $script:activityKind = '' }
      try { $script:activityTool = [string]$state.activityTool } catch { $script:activityTool = '' }
      $script:isError = ($state.error -eq $true) -or ($script:activityKind -eq 'error')
      if ($null -ne $state.alerts) {
        $alerts = @($state.alerts | Where-Object { $null -ne $_ })
      }
    }

    $focused = $true
    if ($null -ne $state -and $null -ne $state.focused) {
      $focused = [bool]$state.focused
    }
    $nowSeconds = $script:clock.Elapsed.TotalSeconds
    if (-not $focused -and $running -lt $script:lastRunningCount -and $pending -eq 0 -and $completed -eq 0) {
      $script:recentCompletionUntil = $nowSeconds + 4.0
    }
    $script:lastRunningCount = $running
    $recentCompletion = ($nowSeconds -lt $script:recentCompletionUntil)
    $script:recentCompletion = $recentCompletion

    $attentionSignature = ''
    $script:pendingKind = ''
    if ($pending -gt 0) {
      $firstAttention = $null
      foreach ($alert in $alerts) {
        if ([string]$alert.kind -ne 'completed') {
          $firstAttention = $alert
          break
        }
      }
      if ($null -ne $firstAttention) {
        $script:pendingKind = [string]$firstAttention.kind
        $attentionSignature = '{0}|{1}|{2}|{3}|{4}' -f $pending, [string]$firstAttention.sessionId, [string]$firstAttention.kind, [string]$firstAttention.title, [string]$firstAttention.preview
      } else {
        $attentionSignature = '{0}|sin-detalle' -f $pending
      }
    }

    $recentStarted = $recentCompletion -and (-not $script:lastRecentCompletion)
    $completedIncreased = $completed -gt $script:lastCompletedCount
    if ($script:soundPrimed) {
      if ($pending -gt 0 -and $attentionSignature -ne $script:lastAttentionSignature) {
        Play-Sound 'attention'
      }
      if ($recentStarted -or $completedIncreased) {
        Play-Sound 'completed'
      }
    }
    $script:lastAttentionSignature = $attentionSignature
    $script:lastCompletedCount = $completed
    $script:lastRecentCompletion = $recentCompletion
    $script:soundPrimed = $true

    $mode = 'idle'
    if ($pending -gt 0) {
      $mode = 'pending'
    } elseif ($script:isError) {
      $mode = 'error'
    } elseif ($completed -gt 0) {
      $mode = 'completed'
    } elseif ($recentCompletion) {
      $mode = 'completed'
    } elseif ($script:stale) {
      $mode = 'stale'
    } elseif ($running -gt 0) {
      $mode = 'running'
    }

    if ($script:mode -ne $mode) {
      $script:mode = $mode
      $script:modeStart = $script:clock.Elapsed.TotalSeconds
    }

    $stateBrush = $script:brushes[$mode]
    $script:aura.Fill = $stateBrush
    $script:badge.Background = $stateBrush
    $script:pill.BorderBrush = $stateBrush

    $animationState = 'idle'
    if ($script:isError) {
      $animationState = 'sad'
    } elseif ($mode -eq 'pending') {
      if ($script:pendingKind -eq 'approval') {
        $animationState = 'approval'
      } else {
        $animationState = 'thinking'
      }
    } elseif ($mode -eq 'completed') {
      if ($recentCompletion) {
        $animationState = 'excited'
      } else {
        $animationState = 'happy'
      }
    } elseif ($mode -eq 'stale') {
      $animationState = 'sleeping'
    } elseif ($mode -eq 'running') {
      switch ($script:activityKind) {
        'commands' { $animationState = 'commands' }
        'code' { $animationState = 'commands' }
        'write' { $animationState = 'writing' }
        'edit' { $animationState = 'writing' }
        'read' { $animationState = 'searching' }
        'search' { $animationState = 'searching' }
        'webSearch' { $animationState = 'searching' }
        'webFetch' { $animationState = 'searching' }
        default { $animationState = 'thinking' }
      }
    }
    $script:animationState = $animationState

    $badgeCount = 0
    if ($pending -gt 0) {
      $badgeCount = $pending
    } elseif ($completed -gt 0) {
      $badgeCount = $completed
    }
    if ($badgeCount -gt 0) {
      $script:badgeLabel.Text = Get-CountText $badgeCount
      $script:badge.Visibility = [System.Windows.Visibility]::Visible
    } elseif ($recentCompletion) {
      $script:badgeLabel.Text = '✓'
      $script:badge.Visibility = [System.Windows.Visibility]::Visible
    } elseif ($script:isError) {
      $script:badgeLabel.Text = '!'
      $script:badge.Visibility = [System.Windows.Visibility]::Visible
    } else {
      $script:badge.Visibility = [System.Windows.Visibility]::Collapsed
    }

    $pillText = ''
    if ($pending -gt 0) {
      $firstPending = $null
      foreach ($alert in $alerts) {
        if ([string]$alert.kind -ne 'completed') {
          $firstPending = $alert
          break
        }
      }
      $reason = 'Esperando respuesta'
      if ($null -ne $firstPending) {
        $reason = Get-Reason ([string]$firstPending.kind)
      }
      $pillText = '{0} · {1}' -f $reason, (Get-CountText $pending)
    } elseif ($completed -gt 0) {
      $pillText = 'Finalizada · {0}' -f (Get-CountText $completed)
    } elseif ($recentCompletion) {
      $pillText = 'Finalizada'
    } elseif ($script:isError) {
      $pillText = 'Error'
    }

    if ($pillText -ne '') {
      $script:pillLabel.Text = $pillText
      $script:pill.Visibility = [System.Windows.Visibility]::Visible
    } else {
      $script:pill.Visibility = [System.Windows.Visibility]::Collapsed
    }

    $bubbleText = 'Trabajando...'
    $showBubble = $false
    if ($pending -gt 0) {
      $showBubble = $true
      if ($script:pendingKind -eq 'approval') {
        $bubbleText = 'Necesita tu aprobación'
      } elseif ($script:pendingKind -eq 'planReview') {
        $bubbleText = 'Revisa el plan'
      } else {
        $bubbleText = 'Te está preguntando algo'
      }
    } elseif ($script:isError) {
      $showBubble = $true
      $bubbleText = 'Algo falló'
    } elseif ($completed -gt 0) {
      $showBubble = $true
      $bubbleText = '¡Listo!'
    } elseif ($recentCompletion) {
      $showBubble = $true
      $bubbleText = '¡Genial!'
    } elseif ($running -gt 0) {
      $showBubble = $true
      switch ($script:activityKind) {
        'commands' { $bubbleText = 'Shell...' }
        'code' { $bubbleText = 'Codeando...' }
        'write' { $bubbleText = 'Escribiendo...' }
        'edit' { $bubbleText = 'Editando...' }
        'read' { $bubbleText = 'Leyendo...' }
        'search' { $bubbleText = 'Buscando...' }
        'webSearch' { $bubbleText = 'Buscando en web...' }
        'webFetch' { $bubbleText = 'Leyendo web...' }
        'subagents' { $bubbleText = 'Esperando subagente...' }
        'plan' { $bubbleText = 'Planificando...' }
        'questions' { $bubbleText = 'Preguntando...' }
        'thinking' { $bubbleText = 'Razonando...' }
        'tools' {
          if ([string]::IsNullOrWhiteSpace($script:activityTool)) {
            $bubbleText = 'Trabajando...'
          } else {
            $bubbleText = 'Usando {0}...' -f $script:activityTool
          }
        }
        default { $bubbleText = 'Trabajando...' }
      }
    }

    $script:bubbleLabel.Text = $bubbleText
    $script:bubble.BorderBrush = $script:brushes[$mode]
    if ($showBubble) {
      $script:bubbleLayer.Visibility = [System.Windows.Visibility]::Visible
    } else {
      $script:bubbleLayer.Visibility = [System.Windows.Visibility]::Collapsed
    }

    foreach ($sparkle in $script:sparkles) {
      if ($mode -eq 'completed') {
        $sparkle.Shape.Visibility = [System.Windows.Visibility]::Visible
      } else {
        $sparkle.Shape.Visibility = [System.Windows.Visibility]::Collapsed
        $sparkle.Shape.Opacity = 0
      }
    }

    $lines = @()
    if ($script:stale) {
      $lines += 'Sin conexión con DSH; mostrando el último estado conocido.'
    }
    if ($script:isError) {
      $lines += 'La última ejecución falló.'
    }
    if ($alerts.Count -eq 0) {
      $lines += 'Todo al día.'
    } else {
      foreach ($alert in ($alerts | Select-Object -First 8)) {
        $title = [string]$alert.title
        if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Sesión' }
        $reason = Get-Reason ([string]$alert.kind)
        $preview = [string]$alert.preview
        if ([string]::IsNullOrWhiteSpace($preview)) {
          $lines += ('{0} — {1}' -f $title, $reason)
        } else {
          $lines += ('{0} — {1} — {2}' -f $title, $reason, $preview)
        }
      }
      $totalAlerts = $pending + $completed
      if ($totalAlerts -gt $alerts.Count) {
        $lines += ('… y {0} más' -f ($totalAlerts - $alerts.Count))
      }
    }
    if ($recentCompletion -and $completed -eq 0 -and $alerts.Count -eq 0) {
      $lines += 'Una sesión acaba de finalizar.'
    }
    $script:toolTipText.Text = ($lines -join [Environment]::NewLine)
    [DshOverlayHitTest]::BadgeVisible = ($script:badge.Visibility -eq [System.Windows.Visibility]::Visible)
    [DshOverlayHitTest]::PillVisible = ($script:pill.Visibility -eq [System.Windows.Visibility]::Visible)
  }

  function Update-Animation {
    $t = $script:clock.Elapsed.TotalSeconds
    $mode = $script:mode
    $move = $script:petMove
    $rotate = $script:petRotate
    $scale = $script:petScale

    $move.X = 0.0
    $move.Y = 0.0
    $rotate.Angle = 0.0
    $scale.ScaleX = 1.0
    $scale.ScaleY = 1.0
    $script:leftArmRotate.Angle = 0.0
    $script:rightArmRotate.Angle = 0.0
    $script:eyeScale.ScaleY = 1.0
    $script:shadowScale.ScaleX = 1.0
    $script:shadow.Opacity = 0.16

    switch ($mode) {
      'idle' {
        $move.Y = -4.0 + (4.0 * [Math]::Sin($t * 2.0))
        $rotate.Angle = 2.0 * [Math]::Sin($t * 1.2)
        $scale.ScaleX = 1.0 + (0.008 * [Math]::Sin($t * 2.0))
        $scale.ScaleY = 1.0 - (0.008 * [Math]::Sin($t * 2.0))
        $script:leftArmRotate.Angle = 2.0 * [Math]::Sin($t * 1.6)
        $script:rightArmRotate.Angle = -2.0 * [Math]::Sin($t * 1.6)
        $script:aura.Opacity = 0.18 + (0.04 * [Math]::Sin($t * 1.5))
      }
      'running' {
        $move.Y = -6.0 + (6.0 * [Math]::Sin($t * 6.0))
        $rotate.Angle = 4.0 * [Math]::Sin($t * 3.2)
        $scale.ScaleX = 1.0 - (0.02 * [Math]::Sin($t * 6.0))
        $scale.ScaleY = 1.0 + (0.02 * [Math]::Sin($t * 6.0))
        $script:leftArmRotate.Angle = 24.0 * [Math]::Sin($t * 6.0)
        $script:rightArmRotate.Angle = -24.0 * [Math]::Sin($t * 6.0)
        $script:aura.Opacity = 0.26 + (0.06 * [Math]::Sin($t * 4.0))
      }
      'pending' {
        $move.X = 3.0 * [Math]::Sin($t * 9.0)
        $move.Y = -8.0 + (3.0 * [Math]::Sin($t * 6.0))
        $rotate.Angle = 3.0 * [Math]::Sin($t * 7.0)
        $scale.ScaleX = 1.03 + (0.02 * [Math]::Sin($t * 5.0))
        $scale.ScaleY = 1.03 - (0.02 * [Math]::Sin($t * 5.0))
        $script:leftArmRotate.Angle = 34.0 * [Math]::Sin($t * 9.0)
        $script:rightArmRotate.Angle = -34.0 * [Math]::Sin($t * 9.0)
        $script:aura.Opacity = 0.36 + (0.08 * [Math]::Sin($t * 5.0))
      }
      'completed' {
        $elapsed = $t - $script:modeStart
        if ($elapsed -lt 2.0) {
          $rotate.Angle = ($elapsed * 360.0) % 360.0
          $move.Y = -12.0 * [Math]::Abs([Math]::Sin($elapsed * 6.0))
          $scale.ScaleX = 1.0 + (0.04 * [Math]::Sin($elapsed * 12.0))
          $scale.ScaleY = 1.0 - (0.04 * [Math]::Sin($elapsed * 12.0))
        } else {
          $move.Y = -4.0 + (4.0 * [Math]::Sin($t * 2.0))
          $rotate.Angle = 2.0 * [Math]::Sin($t * 1.4)
          $scale.ScaleX = 1.0 + (0.01 * [Math]::Sin($t * 2.0))
          $scale.ScaleY = 1.0 - (0.01 * [Math]::Sin($t * 2.0))
        }
        $script:leftArmRotate.Angle = 20.0 * [Math]::Sin($t * 4.0)
        $script:rightArmRotate.Angle = -20.0 * [Math]::Sin($t * 4.0)
        $script:aura.Opacity = 0.35 + (0.10 * [Math]::Sin($t * 3.0))
        $index = 0
        foreach ($sparkle in $script:sparkles) {
          $phase = (($t * 3.0) + ($index * 0.7) + $sparkle.Phase) % 2.0
          $sparkle.Shape.Opacity = [Math]::Max(0.0, 1.0 - [Math]::Abs($phase - 1.0))
          $sparkleScale = 0.6 + (0.6 * [Math]::Abs([Math]::Sin($phase * 3.14159)))
          $sparkle.Scale.ScaleX = $sparkleScale
          $sparkle.Scale.ScaleY = $sparkleScale
          $index++
        }
      }
      'stale' {
        $move.Y = -2.0 + (2.0 * [Math]::Sin($t * 1.2))
        $rotate.Angle = 0.0
        $scale.ScaleX = 1.0
        $scale.ScaleY = 1.0
        $script:leftArmRotate.Angle = 0.0
        $script:rightArmRotate.Angle = 0.0
        $script:aura.Opacity = 0.10
        $script:eyeScale.ScaleY = 0.12
      }
    }

    if ($mode -ne 'stale' -and $mode -ne 'completed') {
      $blinkPhase = $t % 4.2
      if ($blinkPhase -gt 4.0) {
        $script:eyeScale.ScaleY = 0.08
      }
    }

    $shadowPhase = [Math]::Sin($t * 2.0)
    $script:shadowScale.ScaleX = 0.92 + (0.06 * $shadowPhase)
    if ($mode -eq 'running') {
      $script:shadow.Opacity = 0.12 + (0.04 * [Math]::Abs([Math]::Sin($t * 6.0)))
    } elseif ($mode -eq 'pending') {
      $script:shadow.Opacity = 0.14 + (0.03 * [Math]::Abs([Math]::Sin($t * 9.0)))
    } else {
      $script:shadow.Opacity = 0.16
    }

    if ($script:useGengarFrames) {
      $setName = $script:animationState
      $frames = $script:gengarFrames[$setName]
      if ($null -eq $frames -or $frames.Count -eq 0) {
        $frames = $script:gengarFrames.idle
        $setName = 'idle'
      }
      if ($null -ne $frames -and $frames.Count -gt 0) {
        $fps = 4.0
        if ($setName -eq 'commands') { $fps = 10.0 }
        elseif ($setName -eq 'searching') { $fps = 8.0 }
        elseif ($setName -eq 'approval') { $fps = 8.0 }
        elseif ($setName -eq 'excited') { $fps = 8.0 }
        elseif ($setName -eq 'writing') { $fps = 6.0 }
        elseif ($setName -eq 'happy') { $fps = 6.0 }
        elseif ($setName -eq 'sad') { $fps = 3.0 }
        elseif ($setName -eq 'sleeping') { $fps = 1.0 }

        $frameIndex = [int]($t * $fps) % $frames.Count
        if ($frameIndex -ne $script:lastGengarFrame -or $setName -ne $script:gengarSetName) {
          $script:gengarImage.Source = $frames[$frameIndex]
          $script:lastGengarFrame = $frameIndex
          $script:gengarSetName = $setName
        }

        $gx = 0.0
        $gy = 0.0
        $gAngle = 0.0
        $gScaleX = 1.0
        $gScaleY = 1.0
        if ($mode -eq 'idle') {
          $gy = -3.0 + (3.0 * [Math]::Sin($t * 2.0))
          $gAngle = 1.5 * [Math]::Sin($t * 1.3)
        } elseif ($mode -eq 'running') {
          $gy = -5.0 + (5.0 * [Math]::Sin($t * 7.0))
          $gAngle = 3.0 * [Math]::Sin($t * 4.0)
          $gScaleX = 1.02
          $gScaleY = 1.02
        } elseif ($mode -eq 'pending') {
          $gx = 2.0 * [Math]::Sin($t * 9.0)
          $gy = -4.0 + (2.0 * [Math]::Sin($t * 6.0))
          $gAngle = 3.0 * [Math]::Sin($t * 7.0)
          $gScaleX = 1.03
          $gScaleY = 1.03
        } elseif ($mode -eq 'completed') {
          $elapsed = $t - $script:modeStart
          if ($elapsed -lt 2.0) {
            $gAngle = ($elapsed * 360.0) % 360.0
            $gy = -10.0 * [Math]::Abs([Math]::Sin($elapsed * 6.0))
            $gScaleX = 1.0 + (0.04 * [Math]::Sin($elapsed * 12.0))
            $gScaleY = 1.0 - (0.04 * [Math]::Sin($elapsed * 12.0))
          } else {
            $gy = -3.0 + (3.0 * [Math]::Sin($t * 2.0))
            $gAngle = 1.5 * [Math]::Sin($t * 1.3)
          }
        } elseif ($mode -eq 'error') {
          $gx = 1.5 * [Math]::Sin($t * 14.0)
          $gy = 1.0 * [Math]::Sin($t * 10.0)
          $gAngle = 1.5 * [Math]::Sin($t * 12.0)
        } elseif ($mode -eq 'stale') {
          $gy = -1.0 + (1.0 * [Math]::Sin($t * 1.2))
        }

        $script:gengarMove.X = $gx
        $script:gengarMove.Y = $gy
        $script:gengarRotate.Angle = $gAngle
        $script:gengarScale.ScaleX = $gScaleX
        $script:gengarScale.ScaleY = $gScaleY
      }
    }
  }

  $script:stateTimer = [System.Windows.Threading.DispatcherTimer]::new()
  $script:stateTimer.Interval = [TimeSpan]::FromMilliseconds(500)
  $script:stateTimer.Add_Tick({
    Read-State
    Update-Ui
  })

  $script:animTimer = [System.Windows.Threading.DispatcherTimer]::new()
  $script:animTimer.Interval = [TimeSpan]::FromMilliseconds(33)
  $script:animTimer.Add_Tick({
    Update-Animation
  })

  Read-State
  Update-Ui
  Update-Animation
  $script:stateTimer.Start()
  $script:animTimer.Start()

  Write-Log 'overlay started'
  [void]$script:window.ShowDialog()
  Write-Log 'overlay closed'
} catch {
  Write-Log ('fatal: ' + $_.Exception.ToString())
  try {
    [System.Windows.MessageBox]::Show(
      ('No se pudo iniciar el overlay de DSH Session Notifier.' + [Environment]::NewLine + [Environment]::NewLine + $_.Exception.Message),
      'DSH Session Notifier'
    ) | Out-Null
  } catch {
  }
} finally {
  try { if ($null -ne $script:stateTimer) { $script:stateTimer.Stop() } } catch {}
  try { if ($null -ne $script:animTimer) { $script:animTimer.Stop() } } catch {}
  try { if ($ownsMutex -and $null -ne $mutex) { $mutex.ReleaseMutex() } } catch {}
  try { if ($null -ne $mutex) { $mutex.Dispose() } } catch {}
}
