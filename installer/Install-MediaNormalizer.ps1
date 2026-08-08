[CmdletBinding(DefaultParameterSetName='Select')]
param(
    [Parameter(ParameterSetName='Select')][switch]$SelectOutputRoot,
    [Parameter(ParameterSetName='Environment')][switch]$OutputRootFromEnvironment,
    [switch]$NoOpenFolder
)

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
$productFolderName = 'Media Normalizer'
$executableName = 'MediaNormalizer.exe'
$installerRoot = $PSScriptRoot
$payloadRoot = Join-Path $installerRoot 'payload'
$manifestPath = Join-Path $payloadRoot 'payload-manifest.json'
$commonScript = Join-Path $installerRoot 'MediaNormalizer.Installer.Common.ps1'

if (-not (Test-Path -LiteralPath $commonScript -PathType Leaf)) {
    Write-Host 'MEDIA_NORMALIZER_INSTALLER:INSTALLER_INCOMPLETE 共通検証スクリプトがありません。' -ForegroundColor Red
    exit 1
}
. $commonScript

function Stop-Install([string]$Id, [string]$Message, [int]$Code = 1) {
    Write-Host "MEDIA_NORMALIZER_INSTALLER:$Id $Message" -ForegroundColor Red
    exit $Code
}
function Get-Sha256([string]$Path) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $stream = [IO.File]::OpenRead($Path)
        try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant() }
        finally { $stream.Dispose() }
    } finally { $sha.Dispose() }
}
function Get-StableHash([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text.ToUpperInvariant())
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','').Substring(0,16)
    } finally { $sha.Dispose() }
}
function Select-ParentFolder {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    $dialog.Description = 'Media Normalizer のインストール先となる親フォルダーを選択してください。'
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { exit 3 }
    return $dialog.SelectedPath
}
try {
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Stop-Install 'MANIFEST_INVALID' 'payload manifestがありません。'
    }
    $parent = if ($OutputRootFromEnvironment) {
        [Environment]::GetEnvironmentVariable('MEDIA_NORMALIZER_OUTPUT_ROOT')
    } else { Select-ParentFolder }
    if ([string]::IsNullOrWhiteSpace($parent)) { Stop-Install 'OUTPUT_ROOT_INVALID' '親フォルダーが指定されていません。' 2 }
    $parent = [IO.Path]::GetFullPath($parent)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { Stop-Install 'OUTPUT_ROOT_INVALID' '既存の親フォルダーを指定してください。' 2 }
    if ((Get-Item -LiteralPath $parent -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Stop-Install 'OUTPUT_ROOT_INVALID' 'reparse pointは指定できません。' 4
    }
    $install = Join-Path $parent $productFolderName
    if (Test-Path -LiteralPath $install) {
        Assert-NoReparsePointInPath -Root $parent -Path $install
    }
    $hash = Get-StableHash $install.TrimEnd('\')
    $mutex = New-Object Threading.Mutex($false, "Local\MediaNormalizer-Installer-$hash")
    $taken = $false
    try {
        try { $taken = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $taken = $true }
        if (-not $taken) { Stop-Install 'INSTALLER_BUSY' '同じインストール先の処理が実行中です。' }

        $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($manifest.schemaVersion -ne 1 -or $manifest.productId -ne 'media-normalizer') {
            Stop-Install 'MANIFEST_INVALID' 'payload manifestの形式が不正です。'
        }
        $arch = if ($env:PROCESSOR_ARCHITEW6432 -eq 'ARM64' -or $env:PROCESSOR_ARCHITECTURE -eq 'ARM64') {'win-arm64'} else {'win-x64'}
        $payload = $manifest.payloads.$arch
        if ($null -eq $payload) { Stop-Install 'PAYLOAD_ARCHIVE_MISSING' '対応payloadがありません。' }
        $archive = Join-Path $payloadRoot ([string]$payload.archive)
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { Stop-Install 'PAYLOAD_ARCHIVE_MISSING' 'payload ZIPがありません。' }
        if ((Get-Sha256 $archive) -ne [string]$payload.sha256) { Stop-Install 'PAYLOAD_ARCHIVE_TAMPERED' 'payload ZIPの検証に失敗しました。' }

        $appMutex = New-Object Threading.Mutex($false, "Local\MediaNormalizer-App-$hash")
        $appTaken = $false
        try {
            try { $appTaken = $appMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $appTaken = $true }
            if (-not $appTaken) { Stop-Install 'APP_RUNNING' 'Media Normalizerを終了してください。' }
            $runningLock = Join-Path $install '.media-normalizer-running.lock'
            if (Test-Path -LiteralPath $runningLock) {
                try { $probe=[IO.File]::Open($runningLock,'Open','ReadWrite','None'); $probe.Dispose() }
                catch { Stop-Install 'APP_RUNNING' 'Media Normalizerを終了してください。' }
            }

            $stage = Join-Path ([IO.Path]::GetTempPath()) (
                'MediaNormalizerInstaller-' + [Guid]::NewGuid().ToString('N'))
            New-Item -Path $stage -ItemType Directory -Force | Out-Null
            try {
                Expand-Archive -LiteralPath $archive -DestinationPath $stage
                try {
                    $expected = ConvertTo-ValidatedManagedFileMap `
                        -ManagedFiles $payload.managedFiles `
                        -Root $stage
                } catch {
                    Stop-Install 'MANIFEST_INVALID' $_.Exception.Message
                }
                foreach ($managed in $expected.Values) {
                    $name = $managed.Name
                    $path = $managed.Path
                    $file = $managed.Entry
                    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or
                        (Get-Sha256 $path) -ne [string]$file.sha256) {
                        Stop-Install 'PAYLOAD_ARCHIVE_TAMPERED' "展開後検証に失敗しました: $name"
                    }
                }
                $actual = @(Get-ChildItem -LiteralPath $stage -File -Recurse)
                if ($actual.Count -ne $expected.Count) { Stop-Install 'PAYLOAD_ARCHIVE_TAMPERED' 'ZIP内ファイル集合がmanifestと一致しません。' }

                $markerPath = Join-Path $install '.media-normalizer-install.json'
                $oldMarker = $null
                if (Test-Path -LiteralPath $install) {
                    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf) -and @(Get-ChildItem -LiteralPath $install -Force).Count) {
                        Stop-Install 'UNMANAGED_INSTALL' '管理外の同名フォルダーが存在します。'
                    }
                    if (Test-Path -LiteralPath $markerPath) {
                        $oldMarker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
                        if ($oldMarker.schemaVersion -ne 1 -or $oldMarker.productId -ne 'media-normalizer') {
                            Stop-Install 'OLD_MARKER_INVALID' '既存の管理マーカー形式が不正です。'
                        }
                    }
                }
                New-Item -Path $install -ItemType Directory -Force | Out-Null
                $oldManaged = @{}
                if ($oldMarker) {
                    try {
                        $oldManaged = ConvertTo-ValidatedManagedFileMap `
                            -ManagedFiles $oldMarker.managedFiles `
                            -Root $install
                    } catch {
                        Stop-Install 'OLD_MARKER_INVALID' $_.Exception.Message
                    }
                }
                foreach ($managed in $expected.Values) {
                    $name = $managed.Name
                    $target = Resolve-SafeChildPath -Root $install -RelativePath $name
                    Assert-NoReparsePointInPath -Root $install -Path $target
                    if (Test-Path -LiteralPath $target -PathType Container) { Stop-Install 'USER_PATH_CONFLICT' "利用者フォルダーと競合します: $name" }
                    if ((Test-Path -LiteralPath $target) -and -not $oldManaged.ContainsKey($name.ToLowerInvariant())) {
                        Stop-Install 'USER_PATH_CONFLICT' "利用者ファイルと競合します: $name"
                    }
                }

                $backup = Join-Path $env:LOCALAPPDATA "MediaNormalizerInstaller\Backups\backup-$hash"
                $backupNew = "$backup.new"
                if (Test-Path $backupNew) { Remove-Item $backupNew -Recurse -Force }
                New-Item $backupNew -ItemType Directory -Force | Out-Null
                if ($oldMarker) {
                    Copy-Item $markerPath (Join-Path $backupNew '.media-normalizer-install.json')
                    foreach($managed in $oldManaged.Values) {
                        $old = $managed.Path
                        if(Test-Path -LiteralPath $old){$dst=Resolve-SafeChildPath -Root $backupNew -RelativePath $managed.Name;New-Item (Split-Path $dst -Parent) -ItemType Directory -Force|Out-Null;Copy-Item -LiteralPath $old -Destination $dst}
                    }
                }
                $applied=@()
                try {
                    foreach($managed in $expected.Values) {
                        $name=$managed.Name;$dst=Resolve-SafeChildPath -Root $install -RelativePath $name
                        New-Item (Split-Path $dst -Parent) -ItemType Directory -Force|Out-Null
                        Copy-Item -LiteralPath $managed.Path -Destination $dst -Force;$applied+=$name
                    }
                    if($oldMarker){foreach($managed in $oldManaged.Values){$name=$managed.Name;if(-not $expected.ContainsKey($name.ToLowerInvariant())){Remove-Item -LiteralPath $managed.Path -Force}}}
                    $newMarker=[ordered]@{schemaVersion=1;productId='media-normalizer';productVersion=$manifest.productVersion;runtime=$arch;installedAt=(Get-Date).ToUniversalTime().ToString('o');executable=$executableName;manifestSha256=(Get-Sha256 $manifestPath);managedFiles=$payload.managedFiles}
                    $tempMarker="$markerPath.tmp";$newMarker|ConvertTo-Json -Depth 8|Set-Content $tempMarker -Encoding UTF8
                    Move-Item $tempMarker $markerPath -Force
                    if(Test-Path $backup){Remove-Item $backup -Recurse -Force};Move-Item $backupNew $backup
                } catch {
                    foreach($name in $applied){$appliedPath=Resolve-SafeChildPath -Root $install -RelativePath $name;Remove-Item -LiteralPath $appliedPath -Force -ErrorAction SilentlyContinue}
                    if($oldMarker){Get-ChildItem $backupNew -File -Recurse|ForEach-Object{$rel=$_.FullName.Substring($backupNew.Length).TrimStart('\');$dst=Resolve-SafeChildPath -Root $install -RelativePath $rel;New-Item (Split-Path $dst -Parent)-ItemType Directory -Force|Out-Null;Copy-Item -LiteralPath $_.FullName -Destination $dst -Force}}
                    Stop-Install 'APPLY_FAILED_ROLLED_BACK' $_.Exception.Message
                }
                Write-Host "MEDIA_NORMALIZER_INSTALLER:SUCCESS $install" -ForegroundColor Green
                if(-not $NoOpenFolder){Start-Process explorer.exe -ArgumentList $install}
            } finally { Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue }
        } finally { if($appTaken){$appMutex.ReleaseMutex()};$appMutex.Dispose() }
    } finally { if($taken){$mutex.ReleaseMutex()};$mutex.Dispose() }
} catch {
    Stop-Install 'UNEXPECTED_ERROR' $_.Exception.Message
}
