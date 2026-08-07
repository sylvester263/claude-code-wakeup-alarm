<#
Fullscreen fallback player, used when ffplay isn't installed. Windows equivalent of the
QuickTime fallback in lib/play.sh -- a borderless, topmost, always-maximized window
hosting a single MediaElement.

Runs as its own process (launched with -STA, which WPF requires) so lib\play.ps1 can
track and kill it by PID exactly like it does ffplay -- no AppleScript-style IPC needed.

  powershell -STA -File wpf-player.ps1 <path-to-video>
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$VideoPath
)

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        WindowState="Maximized" WindowStyle="None" Topmost="True"
        ShowInTaskbar="False" Background="Black" ResizeMode="NoResize">
  <MediaElement Name="Media" LoadedBehavior="Manual" UnloadedBehavior="Stop" Stretch="Uniform"/>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$media = $window.FindName('Media')
$media.Source = [Uri]::new((Resolve-Path -LiteralPath $VideoPath).Path)

# End of clip, a click, or any keypress all close the window -- lib\play.ps1 also
# force-kills this process the instant you're back, whichever comes first.
$media.Add_MediaEnded({ $window.Close() })
$window.Add_MouseLeftButtonDown({ $window.Close() })
$window.Add_KeyDown({ $window.Close() })
$window.Add_Loaded({ $media.Play() })

$window.ShowDialog() | Out-Null
