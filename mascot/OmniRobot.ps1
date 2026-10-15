<#
.SYNOPSIS
    OmniAgent Görsel Masaüstü Robotu (Sentinel Mascot)
#>
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OptVideo = Join-Path $ScriptDir "gemini_robot_opt.mp4"
$NormalVideo = Join-Path $ScriptDir "gemini_robot.mp4"
$VideoPath = if (Test-Path $OptVideo) { $OptVideo } else { $NormalVideo }
$VideoPath = (Resolve-Path $VideoPath).Path

[xml]$xaml = @"
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    Title="OmniAgent Sentinel"
    Width="280" Height="460"
    WindowStyle="None"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="True"
    WindowStartupLocation="CenterScreen">
    <Grid>
        <Border x:Name="SpeechBubble"
                VerticalAlignment="Top" HorizontalAlignment="Center"
                Margin="10,5,10,0" Padding="12,8"
                Background="#F0101018" CornerRadius="12"
                BorderBrush="#38BDF8" BorderThickness="1.5"
                Opacity="0">
            <StackPanel>
                <TextBlock x:Name="SpeechTitle" Text="OMNIAGENT 7/24" 
                           Foreground="#38BDF8" FontWeight="Bold" FontSize="11" HorizontalAlignment="Center"/>
                <TextBlock x:Name="SpeechText" Text="Nöbetteyim! Elektrik, İnternet ve Güvenlik izleniyor." 
                           Foreground="#FFFFFF" FontSize="11" TextWrapping="Wrap" TextAlignment="Center" Margin="0,3,0,0"/>
            </StackPanel>
        </Border>
        <Border x:Name="RobotContainer"
                VerticalAlignment="Bottom" HorizontalAlignment="Center"
                Width="260" Height="390" Margin="0,0,0,10"
                Background="Transparent" BorderThickness="0" Cursor="Hand">
            <Grid ClipToBounds="True">
                <MediaElement x:Name="RobotVideo"
                              LoadedBehavior="Play" UnloadedBehavior="Manual"
                              Stretch="Uniform" IsMuted="True" ScrubbingEnabled="True"/>
            </Grid>
        </Border>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)
$speechBubble = $window.FindName("SpeechBubble")
$speechTitle = $window.FindName("SpeechTitle")
$speechText = $window.FindName("SpeechText")
$robotContainer = $window.FindName("RobotContainer")
$robotVideo = $window.FindName("RobotVideo")

$robotVideo.Source = [System.Uri]::new($VideoPath)
$robotVideo.Add_MediaEnded({
    $robotVideo.Position = [System.TimeSpan]::Zero
    $robotVideo.Play()
})
$robotContainer.Add_MouseLeftButtonDown({ $window.DragMove() })

$speechTimer = New-Object System.Windows.Threading.DispatcherTimer
$speechTimer.Interval = [TimeSpan]::FromSeconds(6)
$speechTimer.Add_Tick({ $speechBubble.Opacity = 0; $speechTimer.Stop() })

function Show-Speech([string]$Title, [string]$Message) {
    $speechTitle.Text = $Title
    $speechText.Text = $Message
    $speechBubble.Opacity = 1
    $speechTimer.Stop()
    $speechTimer.Start()
}

$robotContainer.Add_MouseLeftButtonUp({
    try {
        $res = Invoke-RestMethod -Uri "http://127.0.0.1:8088/api/reports/summary" -Headers @{"X-Auth-Token"="OmniAgentSecretToken2026"} -TimeoutSec 3
        $msg = "Aktif Sunucu: $($res.online_servers)/$($res.total_servers)`nOnarılan: $($res.healed_issues_24h) | Güvenlik: $($res.security_events_24h)"
        Show-Speech "OMNIAGENT CANLI DURUM" $msg
    } catch {
        Show-Speech "OMNIAGENT" "7/24 Kalkan Aktif!"
    }
})

$contextMenu = New-Object System.Windows.Controls.ContextMenu
$itemDash = New-Object System.Windows.Controls.MenuItem
$itemDash.Header = "🌐 Komuta Panelini Aç (Dashboard)"
$itemDash.Add_Click({ Start-Process "http://localhost:8088" })
$contextMenu.Items.Add($itemDash) | Out-Null

$itemExit = New-Object System.Windows.Controls.MenuItem
$itemExit.Header = "❌ Robotu Kapat"
$itemExit.Add_Click({ $window.Close() })
$contextMenu.Items.Add($itemExit) | Out-Null
$robotContainer.ContextMenu = $contextMenu

$window.Add_Loaded({
    $robotVideo.Play()
    Show-Speech "OMNIAGENT DEVREDE" "7/24 Elektrik, İnternet ve Güvenlik takibi aktif!"
})
$window.ShowDialog() | Out-Null
