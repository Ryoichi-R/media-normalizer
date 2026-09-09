#Requires -Modules Pester

Describe 'Media Normalizer launcher safety contract' {
    BeforeAll {
        $script:projectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $script:launcherSources = @(Get-ChildItem -LiteralPath (
                Join-Path $script:projectRoot 'src\MediaNormalizer.Launcher') -Filter '*.cs' -File)
        $script:launcherSource = ($script:launcherSources | ForEach-Object {
                Get-Content -LiteralPath $_.FullName -Raw
            }) -join "`n"

        function Remove-CSharpCommentsAndStrings {
            param([Parameter(Mandatory)][string]$Source)
            [regex]::Replace(
                $Source,
                '(?s)(//[^\r\n]*|/\*.*?\*/|@"(?:""|[^"])*"|\$?"(?:\\.|[^"\\])*"|''(?:\\.|[^''\\])'')',
                { param($match) ' ' * $match.Length })
        }
        $script:launcherTokens = Remove-CSharpCommentsAndStrings $script:launcherSource
    }

    It '全C# sourceで例外境界・System32 fallback・mutex解放を保持する' {
        $script:launcherSources.Count | Should -BeGreaterThan 1
        $script:launcherSource | Should -Match 'catch \(Exception ex\)'
        $script:launcherSource | Should -Match 'Environment\.SystemDirectory'
        $script:launcherSource | Should -Match 'ReleaseMutex\(\)'
        $script:launcherSource | Should -Match 'ArgumentList\.Add'
    }

    It 'GUIだけをactivation対象としCLI引数は透過する' {
        $program = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'src\MediaNormalizer.Launcher\Program.cs') -Raw
        $program | Should -Match 'if \(args\.Length > 0\)'
        $program | Should -Match 'RunPowerShellAndWait\(shell, script, args'
        $program | Should -Not -Match 'StartsWith\("-Cli'
    }

    It 'child start直後にforeground権を委譲してから待機する' {
        $program = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'src\MediaNormalizer.Launcher\Program.cs') -Raw
        $startIndex = $program.IndexOf('using var guiProcess = StartGuiPowerShell')
        $allowIndex = $program.IndexOf('AllowSetForegroundWindow(guiProcess.Id)', $startIndex)
        $waitIndex = $program.IndexOf('WaitForMainWindow(guiProcess', $startIndex)
        $startIndex | Should -BeGreaterThan -1
        $allowIndex | Should -BeGreaterThan $startIndex
        $allowIndex | Should -BeLessThan $waitIndex
    }

    It 'pipeをpath・user・sessionで分離しcurrent-userと有限I/Oを使用する' {
        $script:launcherSource | Should -Match 'MediaNormalizer-Activation-\{pathHash\}-\{userHash\}-\{sessionId\}'
        $script:launcherSource | Should -Match 'WindowsIdentity\.GetCurrent\(\)\.User'
        $script:launcherSource | Should -Match 'Process\.GetCurrentProcess\(\)\.SessionId'
        $script:launcherSource | Should -Match 'PipeOptions\.CurrentUserOnly'
        $script:launcherSource | Should -Match 'OperationTimeout = TimeSpan\.FromSeconds\(3\)'
        $script:launcherSource | Should -Match 'WaitForConnectionAsync\(_cancellation\.Token\)'
    }

    It 'HWNDを毎poll更新しtop-level製品windowとして複合検証する' {
        $script:launcherSource | Should -Match 'process\.Refresh\(\)'
        $script:launcherSource | Should -Match 'EnumWindows'
        $script:launcherSource | Should -Match 'GetWindowThreadProcessId'
        $script:launcherSource | Should -Match 'IsWindowVisible'
        $script:launcherSource | Should -Match 'GwOwner'
        $script:launcherSource | Should -Match 'メディア音量正規化ツール'
    }

    It 'focus強制APIと恒久TopMostを使用しない' {
        $script:launcherTokens | Should -Not -Match '\bAttachThreadInput\b'
        $script:launcherTokens | Should -Not -Match '\bHWND_TOPMOST\b'
        $script:launcherTokens | Should -Not -Match '\bTopMost\b'
        $script:launcherTokens | Should -Not -Match '\bBringToFront\b'
    }

    It 'running lockをprobeしlauncher固有終了コードを分離する' {
        $script:launcherSource | Should -Match 'CanAcquireRunningLock'
        $script:launcherSource | Should -Match 'FileShare\.None'
        foreach ($code in 20..25) {
            $script:launcherSource | Should -Match "= $code;"
        }
    }

    It 'FlashWindowExを検証済みtaskbar windowだけに使用する' {
        $windowSource = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'src\MediaNormalizer.Launcher\WindowActivator.cs') -Raw
        $windowSource | Should -Match 'IsTaskbarEligible\(window\)'
        $windowSource | Should -Match 'GetForegroundWindow\(\) != window'
        $windowSource | Should -Match 'FlashWindowEx'
    }

    It 'ShownでSW_SHOW後にActivateを一度だけ実行する' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'lib\MediaNormalizer.Ui.psm1') -Raw
        $shown = [regex]::Match($source, '(?s)\$State\.Form\.Add_Shown\(\{.*?\}\.GetNewClosure\(\)\)').Value
        $showIndex = $shown.IndexOf('ShowWindow')
        $activateIndex = $shown.IndexOf('.Activate()')
        $showIndex | Should -BeGreaterThan -1
        $activateIndex | Should -BeGreaterThan $showIndex
        ([regex]::Matches($shown, '\.Activate\(\)')).Count | Should -Be 1
        $shown | Should -Not -Match 'BringToFront|TopMost'
    }

    It 'FormClosingは直接killせずキャンセル要求へ統一する' {
        $source = Get-Content -LiteralPath (
            Join-Path $script:projectRoot 'lib\MediaNormalizer.Ui.psm1') -Raw
        $formClosing = [regex]::Match(
            $source,
            '(?s)# === FormClosing:.*?# === Apply persisted settings ===').Value

        $formClosing | Should -Match '\$eventArgs\.Cancel = \$true'
        $formClosing | Should -Match '\$stateRef\.OperationState -ne ''Idle'''
        $formClosing | Should -Match 'requestCancellationFn'
        $formClosing | Should -Not -Match '\.Kill\('
    }
}
