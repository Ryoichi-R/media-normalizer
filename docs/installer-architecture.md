# Installer architecture

## 信頼境界

manifestとZIPのSHA-256は破損・単独変更を検出する。コード署名を行わないため、
manifestとZIPを同時に差し替える攻撃に対する真正性は保証しない。

## 更新順序

1. install path由来mutexを取得
2. app mutex、EXE lock、lifetime lockを確認
3. ZIP hashとmanifestを検証
4. `%TEMP%\MediaNormalizerInstaller-<hash>\.staging-<guid>`へ展開
5. 全管理対象のbytes・SHA-256・ファイル集合を検証
6. 旧marker記載ファイルだけを一世代バックアップ
7. 新管理対象を反映し、旧版だけの管理対象を削除
8. markerを最後にatomic置換
9. commit前失敗はバックアップから復元

インストール先leaf `Media Normalizer`と実行ファイル`MediaNormalizer.exe`は
installer内定数であり、manifestから導出しない。

## Failure reason

`PAYLOAD_ARCHIVE_MISSING`、`PAYLOAD_ARCHIVE_TAMPERED`、`MANIFEST_INVALID`、
`OUTPUT_ROOT_INVALID`、`INSTALLER_BUSY`、`APP_RUNNING`、`UNMANAGED_INSTALL`、
`USER_PATH_CONFLICT`、`APPLY_FAILED_ROLLED_BACK`、`UNEXPECTED_ERROR`を
`MEDIA_NORMALIZER_INSTALLER:<ID>`形式で出力する。
