# Media Normalizer installer

`Install-MediaNormalizer.ps1`はWindows PowerShell 5.1対応の導入・更新処理です。
利用者はルートの入口BATから実行してください。

更新ではmanifestに記録された管理対象だけを置換し、利用者追加ファイルと
`%APPDATA%\media-normalizer`を変更しません。旧管理対象は
`%LOCALAPPDATA%\MediaNormalizerInstaller\Backups\backup-<hash>`へ一世代保存します。
新旧両方の管理ファイル一覧は、相対パス形式、正規化後のインストール先包含、
大文字小文字を無視した重複、既存reparse pointを検証します。不正な旧管理マーカーは
更新・削除へ使用せず`OLD_MARKER_INVALID`で停止します。

通常アンインストールはインストール先の`Media Normalizer`フォルダーを、アプリ終了後に
手動削除します。完全削除では、必要に応じて上記バックアップと
`%APPDATA%\media-normalizer`も手動削除してください。後者には利用者設定が含まれます。
