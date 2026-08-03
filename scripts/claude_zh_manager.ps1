param(
    [ValidateSet("gui", "status", "install", "repair", "uninstall")]
    [string]$Action = "gui"
)

$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:InstallerPath = Join-Path $PSScriptRoot "install_windows.ps1"
$script:LogPath = Join-Path $script:ProjectRoot "install-windows.log"
$script:RegisteredLanguageList = '["en-US","de-DE","fr-FR","ko-KR","ja-JP","es-419","es-ES","it-IT","hi-IN","pt-BR","id-ID","zh-CN"]'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ClaudePackageInfo {
    $package = Get-AppxPackage -Name "Claude" -ErrorAction SilentlyContinue |
        Where-Object { $_.InstallLocation -and (Test-Path -LiteralPath $_.InstallLocation) } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $package) {
        return $null
    }

    $resourcesPath = Join-Path $package.InstallLocation "app\resources"
    [pscustomobject]@{
        Version = [string]$package.Version
        InstallLocation = [string]$package.InstallLocation
        InstallId = Split-Path -Leaf $package.InstallLocation
        ResourcesPath = $resourcesPath
    }
}

function Test-JsonFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    try {
        $null = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return $true
    }
    catch {
        return $false
    }
}

function Find-LanguageRegistration {
    param([string]$ResourcesPath)

    $assetsPath = Join-Path $ResourcesPath "app.asar.unpacked\.vite\renderer\main_window\assets"
    if (-not (Test-Path -LiteralPath $assetsPath -PathType Container)) {
        $assetsPath = Join-Path $ResourcesPath "ion-dist\assets\v1"
    }
    if (-not (Test-Path -LiteralPath $assetsPath -PathType Container)) {
        return $null
    }

    foreach ($file in Get-ChildItem -LiteralPath $assetsPath -Filter "*.js" -File -ErrorAction SilentlyContinue) {
        try {
            $text = [IO.File]::ReadAllText($file.FullName)
            if ($text.Contains($script:RegisteredLanguageList)) {
                return $file.FullName
            }
        }
        catch {
        }
    }
    return $null
}

function Get-LocaleConfigurationState {
    $paths = @(
        (Join-Path $env:LOCALAPPDATA "Claude\config.json"),
        (Join-Path $env:LOCALAPPDATA "Claude-3p\config.json"),
        (Join-Path $env:APPDATA "Claude\config.json")
    ) | Select-Object -Unique

    $existing = 0
    $zhCn = 0
    foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            continue
        }
        $existing++
        try {
            $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
            if ($text -match '"locale"\s*:\s*"zh-CN"') {
                $zhCn++
            }
        }
        catch {
        }
    }

    [pscustomobject]@{
        Existing = $existing
        ZhCn = $zhCn
    }
}

function Get-ManagerState {
    $package = Get-ClaudePackageInfo
    if (-not $package) {
        return [pscustomobject]@{
            Code = "claude_missing"
            Title = "未找到 Claude Desktop"
            Message = "没有检测到已安装的 Claude Desktop（MSIX 版本）。"
            Version = "—"
            InstallLocation = ""
            ResourcesValid = 0
            ResourcesExpected = 3
            Registered = $false
            RegistrationFile = ""
            LocaleFiles = 0
            LocaleZhCn = 0
            BackupVersions = 0
            CurrentVersionBackups = 0
        }
    }

    $resourceFiles = @(
        (Join-Path $package.ResourcesPath "ion-dist\i18n\zh-CN.json"),
        (Join-Path $package.ResourcesPath "zh-CN.json"),
        (Join-Path $package.ResourcesPath "ion-dist\i18n\statsig\zh-CN.json")
    )
    $validCount = @($resourceFiles | Where-Object { Test-JsonFile $_ }).Count
    $registrationFile = Find-LanguageRegistration $package.ResourcesPath
    $locale = Get-LocaleConfigurationState

    $backupBase = Join-Path $env:LOCALAPPDATA "ClaudeZhCnMinimal\backups"
    $backupVersions = if (Test-Path -LiteralPath $backupBase -PathType Container) {
        @(Get-ChildItem -LiteralPath $backupBase -Directory -ErrorAction SilentlyContinue).Count
    }
    else {
        0
    }
    $currentBackupRoot = Join-Path $backupBase $package.InstallId
    $currentVersionBackups = if (Test-Path -LiteralPath $currentBackupRoot -PathType Container) {
        @(Get-ChildItem -LiteralPath $currentBackupRoot -Directory -ErrorAction SilentlyContinue).Count
    }
    else {
        0
    }

    $hasAnyArtifact = ($validCount -gt 0) -or [bool]$registrationFile
    $fullyInstalled = ($validCount -eq $resourceFiles.Count) -and [bool]$registrationFile

    if ($fullyInstalled -and (($locale.Existing -eq 0) -or ($locale.ZhCn -gt 0))) {
        $code = "installed"
        $title = "汉化已安装"
        $message = "当前 Claude 版本的中文资源和语言注册均正常。"
    }
    elseif ($fullyInstalled) {
        $code = "partial"
        $title = "需要修复语言设置"
        $message = "中文资源完整，但 Claude 的语言设置没有指向 zh-CN。"
    }
    elseif ($hasAnyArtifact) {
        $code = "partial"
        $title = "汉化不完整"
        $message = "检测到部分中文文件或注册项，建议点击【修复汉化】。"
    }
    elseif (($backupVersions -gt 0) -and ($currentVersionBackups -eq 0)) {
        $code = "needs_repair"
        $title = "Claude 更新后需要修复"
        $message = "当前版本没有汉化；检测到旧版本记录，通常是 Claude 更新导致的。"
    }
    else {
        $code = "not_installed"
        $title = "尚未汉化"
        $message = "可以为当前 Claude 版本安装简体中文语言包。"
    }

    [pscustomobject]@{
        Code = $code
        Title = $title
        Message = $message
        Version = $package.Version
        InstallLocation = $package.InstallLocation
        ResourcesValid = $validCount
        ResourcesExpected = $resourceFiles.Count
        Registered = [bool]$registrationFile
        RegistrationFile = [string]$registrationFile
        LocaleFiles = $locale.Existing
        LocaleZhCn = $locale.ZhCn
        BackupVersions = $backupVersions
        CurrentVersionBackups = $currentVersionBackups
    }
}

function Get-ElevationArguments {
    param([string]$RequestedAction)

    return @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"{0}"' -f $PSCommandPath),
        "-Action", $RequestedAction
    )
}

function Start-ElevatedManager {
    param(
        [string]$RequestedAction,
        [switch]$Wait
    )

    try {
        $parameters = @{
            FilePath = "powershell.exe"
            Verb = "RunAs"
            ArgumentList = (Get-ElevationArguments $RequestedAction)
            PassThru = $true
        }
        if ($Wait) {
            $parameters.Wait = $true
        }
        return Start-Process @parameters
    }
    catch {
        throw "没有取得管理员权限，操作已取消。"
    }
}

function Invoke-CoreAction {
    param([ValidateSet("install", "uninstall")][string]$CoreAction)

    if (-not (Test-Path -LiteralPath $script:InstallerPath -PathType Leaf)) {
        throw "找不到核心安装脚本：$script:InstallerPath"
    }

    $oldSkipUpdate = $env:CLAUDE_ZH_SKIP_UPDATE_CHECK
    $env:CLAUDE_ZH_SKIP_UPDATE_CHECK = "1"
    try {
        $arguments = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", ('"{0}"' -f $script:InstallerPath),
            "-Action", $CoreAction,
            "-Language", "zh-CN",
            "-PatchMode", "safe",
            "-SkipAsarPatch"
        )
        $process = Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "核心脚本执行失败（退出代码 $($process.ExitCode)）。请查看安装日志。"
        }
    }
    finally {
        $env:CLAUDE_ZH_SKIP_UPDATE_CHECK = $oldSkipUpdate
    }
}

function Invoke-CommandLineAction {
    param([string]$RequestedAction)

    if (-not (Test-IsAdministrator)) {
        $process = Start-ElevatedManager -RequestedAction $RequestedAction -Wait
        exit $process.ExitCode
    }

    if ($RequestedAction -eq "uninstall") {
        Invoke-CoreAction "uninstall"
    }
    else {
        Invoke-CoreAction "install"
    }
}

function Show-ManagerWindow {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude 简体中文管理器" Height="535" Width="720"
        WindowStartupLocation="CenterScreen" ResizeMode="CanMinimize"
        Background="#F7F4EF" FontFamily="Microsoft YaHei UI">
  <Grid Margin="28">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="18"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="18"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0">
      <TextBlock Text="Claude 简体中文管理器" FontSize="26" FontWeight="SemiBold" Foreground="#29241F"/>
      <TextBlock Text="当前版本自动识别 · 更新后可一键修复 · 不修改账号与 3P 模型配置" Margin="0,8,0,0" FontSize="13" Foreground="#6D655C"/>
    </StackPanel>

    <Border Grid.Row="2" Background="White" CornerRadius="14" BorderBrush="#E4DDD4" BorderThickness="1" Padding="22">
      <Grid>
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="16"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="16"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <Grid Grid.Row="0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <StackPanel>
            <TextBlock x:Name="StatusTitle" Text="正在检测…" FontSize="21" FontWeight="SemiBold" Foreground="#29241F"/>
            <TextBlock x:Name="StatusMessage" Text="" Margin="0,7,0,0" TextWrapping="Wrap" Foreground="#625B53"/>
          </StackPanel>
          <Border x:Name="StatusBadge" Grid.Column="1" Background="#EEE8DF" CornerRadius="12" Padding="12,6" VerticalAlignment="Top">
            <TextBlock x:Name="StatusBadgeText" Text="检测中" FontWeight="SemiBold" Foreground="#625B53"/>
          </Border>
        </Grid>

        <Border Grid.Row="2" Background="#FAF8F5" CornerRadius="9" Padding="15">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="125"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="9"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="9"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="9"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>
            <TextBlock Grid.Row="0" Text="Claude 版本" Foreground="#81786E"/>
            <TextBlock x:Name="VersionText" Grid.Row="0" Grid.Column="1" Text="—"/>
            <TextBlock Grid.Row="2" Text="中文资源" Foreground="#81786E"/>
            <TextBlock x:Name="ResourcesText" Grid.Row="2" Grid.Column="1" Text="—"/>
            <TextBlock Grid.Row="4" Text="语言注册" Foreground="#81786E"/>
            <TextBlock x:Name="RegistrationText" Grid.Row="4" Grid.Column="1" Text="—"/>
            <TextBlock Grid.Row="6" Text="语言设置" Foreground="#81786E"/>
            <TextBlock x:Name="LocaleText" Grid.Row="6" Grid.Column="1" Text="—"/>
          </Grid>
        </Border>

        <TextBlock x:Name="OperationText" Grid.Row="4" Text="" Foreground="#6D655C" TextWrapping="Wrap"/>

        <StackPanel Grid.Row="5" Orientation="Horizontal" VerticalAlignment="Bottom">
          <Button x:Name="InstallButton" Content="一键汉化" MinWidth="132" Height="42" Margin="0,0,10,0" Background="#D97757" Foreground="White" BorderThickness="0" FontWeight="SemiBold" Cursor="Hand"/>
          <Button x:Name="UninstallButton" Content="卸载汉化" MinWidth="112" Height="42" Margin="0,0,10,0" Background="#EEE8DF" Foreground="#3F3933" BorderBrush="#DCD3C8" Cursor="Hand"/>
          <Button x:Name="RefreshButton" Content="重新检测" MinWidth="100" Height="42" Margin="0,0,10,0" Background="White" Foreground="#3F3933" BorderBrush="#DCD3C8" Cursor="Hand"/>
          <Button x:Name="LogButton" Content="查看日志" MinWidth="100" Height="42" Background="White" Foreground="#3F3933" BorderBrush="#DCD3C8" Cursor="Hand"/>
        </StackPanel>
      </Grid>
    </Border>

    <Grid Grid.Row="4">
      <TextBlock Text="安全模式：不修改 Claude.exe、app.asar，也不读取或改写 API 密钥。" VerticalAlignment="Center" FontSize="12" Foreground="#81786E"/>
      <Button x:Name="CloseButton" Content="关闭" HorizontalAlignment="Right" MinWidth="82" Height="34" Background="Transparent" BorderBrush="#CFC5B9" Cursor="Hand"/>
    </Grid>
  </Grid>
</Window>
'@

    $reader = New-Object System.Xml.XmlNodeReader($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    $statusTitle = $window.FindName("StatusTitle")
    $statusMessage = $window.FindName("StatusMessage")
    $statusBadge = $window.FindName("StatusBadge")
    $statusBadgeText = $window.FindName("StatusBadgeText")
    $versionText = $window.FindName("VersionText")
    $resourcesText = $window.FindName("ResourcesText")
    $registrationText = $window.FindName("RegistrationText")
    $localeText = $window.FindName("LocaleText")
    $operationText = $window.FindName("OperationText")
    $installButton = $window.FindName("InstallButton")
    $uninstallButton = $window.FindName("UninstallButton")
    $refreshButton = $window.FindName("RefreshButton")
    $logButton = $window.FindName("LogButton")
    $closeButton = $window.FindName("CloseButton")

    $script:lastState = $null

    $setBusy = {
        param([bool]$Busy, [string]$Text)
        $installButton.IsEnabled = -not $Busy
        $uninstallButton.IsEnabled = -not $Busy
        $refreshButton.IsEnabled = -not $Busy
        $logButton.IsEnabled = -not $Busy
        $window.Cursor = if ($Busy) { [Windows.Input.Cursors]::Wait } else { [Windows.Input.Cursors]::Arrow }
        $operationText.Text = $Text
        $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render)
    }

    $refresh = {
        try {
            $state = Get-ManagerState
            $script:lastState = $state
            $statusTitle.Text = $state.Title
            $statusMessage.Text = $state.Message
            $versionText.Text = $state.Version
            $resourcesText.Text = "$($state.ResourcesValid) / $($state.ResourcesExpected) 个文件有效"
            $registrationText.Text = if ($state.Registered) { "正常" } else { "缺失" }
            $localeText.Text = if ($state.LocaleFiles -eq 0) { "尚无配置文件" } else { "$($state.LocaleZhCn) / $($state.LocaleFiles) 处为 zh-CN" }

            switch ($state.Code) {
                "installed" {
                    $statusBadge.Background = "#E2F2E8"
                    $statusBadgeText.Foreground = "#277A49"
                    $statusBadgeText.Text = "正常"
                    $installButton.Content = "重新安装"
                }
                "needs_repair" {
                    $statusBadge.Background = "#FFF0D6"
                    $statusBadgeText.Foreground = "#9A5B00"
                    $statusBadgeText.Text = "更新后待修复"
                    $installButton.Content = "修复汉化"
                }
                "partial" {
                    $statusBadge.Background = "#FFF0D6"
                    $statusBadgeText.Foreground = "#9A5B00"
                    $statusBadgeText.Text = "需要修复"
                    $installButton.Content = "修复汉化"
                }
                "claude_missing" {
                    $statusBadge.Background = "#F8DEDE"
                    $statusBadgeText.Foreground = "#A13A3A"
                    $statusBadgeText.Text = "未检测到"
                    $installButton.Content = "一键汉化"
                }
                default {
                    $statusBadge.Background = "#EEE8DF"
                    $statusBadgeText.Foreground = "#625B53"
                    $statusBadgeText.Text = "未安装"
                    $installButton.Content = "一键汉化"
                }
            }
            $installButton.IsEnabled = ($state.Code -ne "claude_missing")
            $uninstallButton.IsEnabled = ($state.Code -in @("installed", "partial"))
        }
        catch {
            $statusTitle.Text = "检测失败"
            $statusMessage.Text = $_.Exception.Message
            $statusBadgeText.Text = "错误"
            $statusBadge.Background = "#F8DEDE"
            $statusBadgeText.Foreground = "#A13A3A"
        }
    }

    $installButton.Add_Click({
        & $setBusy $true "正在关闭 Claude、备份当前版本并安装中文资源，请稍候…"
        try {
            Invoke-CoreAction "install"
            & $refresh
            $operationText.Text = "完成：已为 Claude $($script:lastState.Version) 安装简体中文。"
            [Windows.MessageBox]::Show("汉化安装完成。Claude 已重新启动。", "Claude 简体中文管理器", "OK", "Information") | Out-Null
        }
        catch {
            $operationText.Text = "失败：$($_.Exception.Message)"
            [Windows.MessageBox]::Show("安装失败。$($_.Exception.Message)`n`n可点击【查看日志】了解详情。", "Claude 简体中文管理器", "OK", "Error") | Out-Null
        }
        finally {
            & $setBusy $false $operationText.Text
            & $refresh
        }
    })

    $uninstallButton.Add_Click({
        $answer = [Windows.MessageBox]::Show("确定卸载中文语言包并恢复英文吗？`n`n不会删除 Claude，也不会改动账号或 3P 模型配置。", "确认卸载汉化", "YesNo", "Question")
        if ($answer -ne "Yes") {
            return
        }

        & $setBusy $true "正在恢复原始文件并卸载中文资源，请稍候…"
        try {
            Invoke-CoreAction "uninstall"
            & $refresh
            $operationText.Text = "完成：中文语言包已卸载，Claude 已恢复并重新启动。"
            [Windows.MessageBox]::Show("汉化已卸载。Claude 已恢复为英文并重新启动。", "Claude 简体中文管理器", "OK", "Information") | Out-Null
        }
        catch {
            $operationText.Text = "失败：$($_.Exception.Message)"
            [Windows.MessageBox]::Show("卸载失败。$($_.Exception.Message)`n`n可点击【查看日志】了解详情。", "Claude 简体中文管理器", "OK", "Error") | Out-Null
        }
        finally {
            & $setBusy $false $operationText.Text
            & $refresh
        }
    })

    $refreshButton.Add_Click({
        $operationText.Text = ""
        & $refresh
    })

    $logButton.Add_Click({
        if (Test-Path -LiteralPath $script:LogPath -PathType Leaf) {
            Start-Process -FilePath "notepad.exe" -ArgumentList ('"{0}"' -f $script:LogPath)
        }
        else {
            [Windows.MessageBox]::Show("还没有生成安装日志。", "Claude 简体中文管理器", "OK", "Information") | Out-Null
        }
    })

    $closeButton.Add_Click({ $window.Close() })
    $window.Add_ContentRendered({ & $refresh })
    $window.ShowDialog() | Out-Null
}

switch ($Action) {
    "status" {
        Get-ManagerState | ConvertTo-Json -Depth 4
    }
    "gui" {
        if (-not (Test-IsAdministrator)) {
            $null = Start-ElevatedManager -RequestedAction "gui"
            exit 0
        }
        Show-ManagerWindow
    }
    "install" { Invoke-CommandLineAction "install" }
    "repair" { Invoke-CommandLineAction "repair" }
    "uninstall" { Invoke-CommandLineAction "uninstall" }
}
