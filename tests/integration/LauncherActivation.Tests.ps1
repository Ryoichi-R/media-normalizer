#Requires -Version 7.0
#Requires -Modules Pester

Describe 'Media Normalizer launcher activation' -Tag 'WindowsOnly', 'Integration' -Skip:(-not $IsWindows -or -not [Environment]::UserInteractive) {
    BeforeAll {
        $projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $fixtureRoot = Join-Path $TestDrive 'launcher-fixture'
        $publishRoot = Join-Path $fixtureRoot 'publish'
        New-Item -ItemType Directory -Path $publishRoot -Force | Out-Null
        & dotnet publish (Join-Path $projectRoot 'src\MediaNormalizer.Launcher\MediaNormalizer.Launcher.csproj') `
            --configuration Release --no-restore --output $publishRoot
        if ($LASTEXITCODE -ne 0) { throw 'Launcher fixture publish failed.' }

        foreach ($relative in @(
                'runtime\ffmpeg\bin\ffmpeg.exe',
                'runtime\ffmpeg\bin\ffprobe.exe',
                'runtime\python\python.exe')) {
            $path = Join-Path $publishRoot $relative
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            New-Item -ItemType File -Path $path -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $publishRoot 'runtime-check.ps1') -Encoding utf8 -Value 'exit 0'
        Set-Content -LiteralPath (Join-Path $publishRoot 'media-normalizer.ps1') -Encoding utf8 -Value @'
Add-Type -AssemblyName System.Windows.Forms
$lock = [IO.File]::Open((Join-Path $PSScriptRoot '.media-normalizer-running.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
try {
    Add-Content -LiteralPath (Join-Path $PSScriptRoot 'gui-pids.txt') -Value $PID
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'メディア音量正規化ツール'
    $form.ShowInTaskbar = $true
    $form.Add_Shown({ $form.Activate() }.GetNewClosure())
    [void]$form.ShowDialog()
}
finally { $lock.Dispose() }
'@

        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class LauncherActivationTestNative {
    public delegate bool EnumProc(IntPtr hwnd, IntPtr parameter);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr parameter);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int count);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd, uint message, IntPtr wparam, IntPtr lparam);
}
'@
        function Find-FixtureWindow {
            $found = [IntPtr]::Zero
            $callback = [LauncherActivationTestNative+EnumProc]{
                param($window, $parameter)
                $title = [Text.StringBuilder]::new(256)
                [void][LauncherActivationTestNative]::GetWindowText($window, $title, $title.Capacity)
                if ($title.ToString() -eq 'メディア音量正規化ツール') {
                    $script:foundFixtureWindow = $window
                    return $false
                }
                return $true
            }
            $script:foundFixtureWindow = [IntPtr]::Zero
            [void][LauncherActivationTestNative]::EnumWindows($callback, [IntPtr]::Zero)
            return $script:foundFixtureWindow
        }
        $script:fixtureRoot = $publishRoot
        $script:launcher = Join-Path $publishRoot 'MediaNormalizer.exe'
    }

    It 'primaryを表示しsecondaryで同一windowを復元する' {
        $primary = Start-Process -FilePath $script:launcher -PassThru
        try {
            $deadline = [Diagnostics.Stopwatch]::StartNew()
            $window = [IntPtr]::Zero
            while ($window -eq [IntPtr]::Zero -and $deadline.Elapsed -lt [TimeSpan]::FromSeconds(30)) {
                Start-Sleep -Milliseconds 50
                $window = Find-FixtureWindow
            }
            $window | Should -Not -Be ([IntPtr]::Zero)

            [void][LauncherActivationTestNative]::ShowWindow($window, 6)
            [LauncherActivationTestNative]::IsIconic($window) | Should -BeTrue
            $secondary = Start-Process -FilePath $script:launcher -PassThru -Wait
            $secondary.ExitCode | Should -Be 0

            $cliSecondary = Start-Process -FilePath $script:launcher -ArgumentList '-C' -PassThru -Wait
            $cliSecondary.ExitCode | Should -Be 2

            $deadline.Restart()
            while ([LauncherActivationTestNative]::IsIconic($window) -and $deadline.Elapsed -lt [TimeSpan]::FromSeconds(5)) {
                Start-Sleep -Milliseconds 50
            }
            [LauncherActivationTestNative]::IsIconic($window) | Should -BeFalse
            @(Get-Content -LiteralPath (Join-Path $script:fixtureRoot 'gui-pids.txt')).Count | Should -Be 1
        }
        finally {
            if ($window -ne [IntPtr]::Zero) {
                [void][LauncherActivationTestNative]::PostMessage($window, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
            if (-not $primary.HasExited) {
                $primary.WaitForExit(5000) | Out-Null
            }
            if (-not $primary.HasExited) { Stop-Process -Id $primary.Id -Force }
            $primary.Dispose()
        }
    }
}
