#Requires -Modules Pester

<#
    TODO.md MN-10 / plans/media-normalizer-ui-responsiveness-remediation-plan.md 設計判断7。
    lib 内で外部プロセスを Invoke-MediaNormalizerProcess runner を経由せず直接・同期実行している
    箇所を AST ベースで検出する。承認済み許可リスト (下記 $script:AllowList) に載っている行は
    許容し、それ以外が 1 件でもあれば fail する。
    行番号ではなく行内容(正規表現)で照合するため、周辺コードの追加・削除による行番号drift耐性を持つ。
#>

Set-StrictMode -Version Latest

function script:Get-ScriptblockTypedParameterNames {
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast]$Ast)
    $names = New-Object System.Collections.Generic.HashSet[string]
    $paramAsts = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.ParameterAst] }, $true)
    foreach ($p in $paramAsts) {
        $isScriptblock = $p.Attributes | Where-Object {
            $_ -is [System.Management.Automation.Language.TypeConstraintAst] -and $_.TypeName.Name -eq 'scriptblock'
        }
        if ($isScriptblock) { [void]$names.Add($p.Name.VariablePath.UserPath) }
    }
    $assignments = $Ast.FindAll({
            param($n)
            $n -is [System.Management.Automation.Language.AssignmentStatementAst]
        }, $true)
    foreach ($assignment in $assignments) {
        $left = $assignment.Left
        if ($left -is [System.Management.Automation.Language.ConvertExpressionAst] -and
            $left.Type.TypeName.Name -eq 'scriptblock' -and
            $left.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
            [void]$names.Add($left.Child.VariablePath.UserPath)
        }
    }
    return ,$names
}

function script:Find-MediaNormalizerBlockingCalls {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "構文解析に失敗しました: $Path"
    }
    $lines = Get-Content -LiteralPath $Path
    $scriptblockNames = Get-ScriptblockTypedParameterNames -Ast $ast

    $violations = [System.Collections.Generic.List[object]]::new()

    # パターン1: リテラル ffmpeg/ffprobe/ffmpeg-normalize/taskkill の CommandAst。
    # パターン2: Start-Process -Wait。
    # パターン4: & $var / . $var のうちparameterまたは代入で$varが
    # [scriptblock]型宣言されていないもの(warning)。
    $commandAsts = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($cmd in $commandAsts) {
        $name = $cmd.GetCommandName()
        if ($name -and ($name -match '^(ffmpeg|ffprobe|ffmpeg-normalize)(\.(exe|cmd|bat))?$' -or $name -match '^taskkill(\.exe)?$')) {
            $violations.Add([pscustomobject]@{
                Kind   = 'error'
                Line   = $cmd.Extent.StartLineNumber
                Reason = "リテラル $name 呼び出し"
            })
        } elseif ($name -eq 'Start-Process') {
            $hasWait = $cmd.CommandElements | Where-Object {
                $_ -is [System.Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'Wait'
            }
            if ($hasWait) {
                $violations.Add([pscustomobject]@{
                    Kind   = 'error'
                    Line   = $cmd.Extent.StartLineNumber
                    Reason = 'Start-Process -Wait'
                })
            }
        } elseif (-not $name) {
            $first = $cmd.CommandElements[0]
            if ($first -is [System.Management.Automation.Language.VariableExpressionAst]) {
                $varName = $first.VariablePath.UserPath
                if (-not $scriptblockNames.Contains($varName)) {
                    $violations.Add([pscustomobject]@{
                        Kind   = 'warning'
                        Line   = $cmd.Extent.StartLineNumber
                        Reason = "非 scriptblock 変数の動的呼び出し: `$$varName"
                    })
                }
            }
        }
    }

    # パターン3: .WaitForExit( の直接呼び出し。
    $memberCalls = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] }, $true)
    foreach ($m in $memberCalls) {
        if ($m.Member -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $m.Member.Value -eq 'WaitForExit') {
            $violations.Add([pscustomobject]@{
                Kind   = 'error'
                Line   = $m.Extent.StartLineNumber
                Reason = '.WaitForExit( の直接呼び出し'
            })
        }
    }

    foreach ($v in $violations) {
        $lineText = if ($v.Line -ge 1 -and $v.Line -le $lines.Count) { $lines[$v.Line - 1] } else { '' }
        Add-Member -InputObject $v -NotePropertyName LineText -NotePropertyValue $lineText -Force
    }

    return @($violations | Sort-Object Line)
}

function script:Test-MediaNormalizerAllowListed {
    param(
        [Parameter(Mandatory)][string]$FileName,
        [Parameter(Mandatory)][string]$LineText
    )
    foreach ($entry in $script:AllowList) {
        if ($entry.File -eq $FileName -and $LineText -match $entry.Pattern) {
            return $true
        }
    }
    return $false
}

Describe 'lib 内の外部プロセス直接待機 (NoBlockingProcessCall)' {
    BeforeAll {
        $script:libRoot = [IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib')
        $script:TargetFiles = @(
            'MediaNormalizer.Core.psm1',
            'MediaNormalizer.Ui.psm1',
            'MediaNormalizer.Probe.psm1',
            'MediaNormalizer.Progress.psm1'
        )

        # @{ File; Function; Pattern; Reason; TodoId } の構造化許可リスト。
        # Pattern は該当行のテキストに対する正規表現。
        $script:AllowList = @(
            @{ File = 'MediaNormalizer.Core.psm1'; Function = 'Invoke-MediaNormalizerProcess'; Pattern = 'taskkill\.exe /T /F /PID \$proc\.Id'; Reason = 'runner 実装本体の CancelAction'; TodoId = $null }
            @{ File = 'MediaNormalizer.Core.psm1'; Function = 'Invoke-MediaNormalizerProcess'; Pattern = '\$proc\.WaitForExit\('; Reason = 'runner実装本体・停止確認後cleanup'; TodoId = $null }
            @{ File = 'MediaNormalizer.Core.psm1'; Function = 'Invoke-MediaNormalizerProcess'; Pattern = '&\s*\$outputPump(?:\s|$)'; Reason = 'POSIX stdout/stderr pump'; TodoId = $null }
            @{ File = 'MediaNormalizer.Core.psm1'; Function = 'Test-FfmpegNormalizePython'; Pattern = '&\s*\$Command\s'; Reason = '-c import の即時終了チェック'; TodoId = $null }
            @{ File = 'MediaNormalizer.Core.psm1'; Function = 'Invoke-NormalizeCli'; Pattern = 'taskkill\.exe /T /F /PID \$state\.RunningProcess\.Id'; Reason = 'CLI終了時の後始末。終了コード上書き問題と併せて扱う'; TodoId = 'MN-2' }
            @{ File = 'MediaNormalizer.Probe.psm1'; Function = 'Get-MediaDuration'; Pattern = '&\s*\$ffprobePath\s'; Reason = '一覧スキャン経路'; TodoId = 'MN-5' }
            @{ File = 'MediaNormalizer.Ui.psm1'; Function = '$script:ProbeScriptBlock'; Pattern = '&\s*ffprobe\s'; Reason = 'ThreadJob 内で別スレッド実行のため UI をブロックしない'; TodoId = 'MN-5' }
        )
    }

    It '許可リスト以外に runner 非経由のブロッキング呼び出しが存在しない' {
        $unexpected = [System.Collections.Generic.List[string]]::new()
        foreach ($fileName in $script:TargetFiles) {
            $path = Join-Path $script:libRoot $fileName
            $violations = Find-MediaNormalizerBlockingCalls -Path $path
            foreach ($v in $violations) {
                if (-not (Test-MediaNormalizerAllowListed -FileName $fileName -LineText $v.LineText)) {
                    $unexpected.Add("[BLOCKING-PROCESS-CALL] ${fileName}:$($v.Line) $($v.Reason)")
                }
            }
        }
        if ($unexpected.Count -gt 0) {
            Write-Host ($unexpected -join "`n")
        }
        $unexpected.Count | Should -Be 0
    }

    It '許可リストの各エントリが実在の行に対応している(死んだ許可リストの検出)' {
        foreach ($entry in $script:AllowList) {
            $path = Join-Path $script:libRoot $entry.File
            $lines = Get-Content -LiteralPath $path
            $matchFound = @($lines | Where-Object { $_ -match $entry.Pattern }).Count -gt 0
            $matchFound | Should -BeTrue -Because "許可リストエントリ '$($entry.File) / $($entry.Function)' に一致する行が見つかりません"
        }
    }

    It 'Core.psm1 の scriptblock 経由の動的呼び出し(約67件)に誤検出しない' {
        $path = Join-Path $script:libRoot 'MediaNormalizer.Core.psm1'
        $violations = Find-MediaNormalizerBlockingCalls -Path $path
        $warnings = @($violations | Where-Object { $_.Kind -eq 'warning' })
        $unexpectedWarnings = @($warnings | Where-Object {
            -not (Test-MediaNormalizerAllowListed -FileName 'MediaNormalizer.Core.psm1' -LineText $_.LineText)
        })
        $unexpectedWarnings.Count | Should -Be 0
    }

    It 'UI event handlerから正規化本体を同期呼出ししない' {
        $path = Join-Path $script:libRoot 'MediaNormalizer.Ui.psm1'
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            $path, [ref]$tokens, [ref]$parseErrors)
        $handler = $ast.FindAll({ param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
                $node.Name -eq 'Register-MainFormEventHandlers'
            }, $true) | Select-Object -First 1
        $handler | Should -Not -BeNullOrEmpty
        $handler.Extent.Text | Should -Not -Match '\bInvoke-Normalize(Ui)?\b'
        $handler.Extent.Text | Should -Match 'Start-UiOperation'
    }

    It '意図的に許可対象外の ffprobe 直接呼び出しを混入させると検出する(検査自体の有効性確認)' {
        $tempFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), "nbc-test-$([guid]::NewGuid().ToString('N')).psm1")
        try {
            Set-Content -LiteralPath $tempFile -Encoding UTF8 -Value @'
function Get-Bogus {
    param([string]$FilePath)
    $raw = & ffprobe -v error $FilePath
    return $raw
}
'@
            $violations = Find-MediaNormalizerBlockingCalls -Path $tempFile
            @($violations | Where-Object { $_.Kind -eq 'error' }).Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }

    It '意図的に Start-Process -Wait を混入させると検出する(検査自体の有効性確認)' {
        $tempFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), "nbc-test-$([guid]::NewGuid().ToString('N')).psm1")
        try {
            Set-Content -LiteralPath $tempFile -Encoding UTF8 -Value @'
function Invoke-Bogus {
    Start-Process -FilePath 'notepad.exe' -Wait
}
'@
            $violations = Find-MediaNormalizerBlockingCalls -Path $tempFile
            @($violations | Where-Object { $_.Kind -eq 'error' -and $_.Reason -match 'Start-Process' }).Count | Should -BeGreaterThan 0
        } finally {
            Remove-Item -LiteralPath $tempFile -Force -ErrorAction SilentlyContinue
        }
    }
}
