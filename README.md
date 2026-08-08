# Media Normalizer

Windows向けの自己完結型ポータブルアプリです。配布ZIPには、動作に必要な
FFmpeg、ffprobe、Python、ffmpeg-normalizeが含まれています。利用者がこれらを
別途インストールしたり、`PATH`を設定したりする必要はありません。

## 主な機能

- 音声ファイルを直接入力できます。
  - 入力: AAC / AIFF / ALAC / FLAC / M4A / MP3 / OGG / Opus / WAV / WMA
  - 動画からの音声出力: MP4 / MOV / MKV / AVI
  - 音声出力: MP3 / M4A / AAC / FLAC / WAV / Opus / OGG
- 「解析のみ」で、各音声トラックのIntegrated Loudness、True Peak、
  Loudness Rangeを測定し、JSONレポートを作成できます。
- 既に目標値の±0.5 LU以内でTrue Peak上限も満たす同一形式ファイルは、
  再圧縮せずバイト列をコピーします。
- ファイル/フォルダのドラッグ＆ドロップ、複数ファイル選択、
  サブフォルダ再帰検索、出力階層の維持に対応します。
- 動画正規化では全音声トラックを処理し、映像、字幕、チャプター、
  コンテナ/ストリームメタデータの保持を処理後に検証します。
- 音声モードで複数の音声トラックを含む入力を処理した場合は、処理後に
  音声トラック数を比較します。出力形式の制約などで減少したトラック数は
  ログとJSONレポートの`droppedAudioStreams`へ明示します。
- 字幕またはチャプター付き動画の速度変更は、字幕/チャプター時刻のずれを
  防ぐため100%以外を拒否します。通常速度での正規化は保持検証を行います。
- HDR、BT.2020、または10bit以上の動画は、現行の速度変更用映像エンコーダーで
  色域・伝達特性・ビット深度を保持できないため、100%以外を安全に拒否します。
  これらの素材は速度100%で正規化するか、HDR対応の外部映像処理を使用してください。
- 動画 + 速度変更時、音声は可逆コーデック（ALAC/FLAC、非対応構成では
  入力精度に応じたPCM）で中間ファイルを作成してから正規化します。これにより
  音声の非可逆エンコード回数が2回から1回に減ります。timecode(`data`)や
  フォント埋め込み等の`attachment`ストリームを持つ入力は、速度変更時に限り
  これらのストリームを除外し、ログとJSONレポートへ理由を残します
  （通常速度・非速度変更の処理では従来どおり保持します）。
- 出力は最終出力と同じフォルダの一時ファイルへ作成し、ffprobe検証と
  処理後ラウドネス解析に合格した場合だけ最終名へ置換します。
  検証に失敗した場合、既存出力は置換しません。
- 各プリセットには用途、規格または運用根拠、注意点を表示します。
  実行前に選択プリセットと現在値の一致を確認できます。

## 起動方法

1. 使用するWindowsに合うZIPを展開します。
   - 一般的なIntel/AMD搭載PC: `media-normalizer-win-x64.zip`
   - Windows on ARM搭載PC: `media-normalizer-win-arm64.zip`
2. 展開したフォルダ内の `media-normalizer.bat` を実行します。

起動時には内蔵ランタイムの存在、SHA-256、バージョン、必要なFFmpeg機能、
一時フォルダの書込権限と空き容量を自動確認します。問題がある場合はGUIを
起動せず、診断結果を表示します。

全診断を手動で表示するには `runtime-check.bat` を実行してください。

> `media-normalizer.bat` だけを別の場所へ移動しないでください。
> `runtime`、`lib`、`assets`を含む展開済みフォルダ全体が必要です。

## GUIの使い方

1. ファイル/フォルダを画面へドロップするか、フォルダ/ファイル選択ボタンで
   入力を指定します。
2. 音声正規化、動画正規化、または両方を選びます。
3. プリセットの根拠表示と現在値を確認します。音声出力形式も選択できます。
4. 必要に応じて「解析のみ」「正規化不要なら再圧縮しない」
   「サブフォルダも再帰検索」「出力に入力階層を維持」を変更します。
5. `[確認]` で対象一覧を確認し、`[実行]` を押します。

入力・出力フォルダは初回起動時には未指定です。一度指定すると終了時に
ユーザー設定へ保存され、次回起動時に同じフォルダが表示されます。

処理結果は出力フォルダの
`media-normalizer-report-YYYYMMDD-HHMMSS.json` に保存されます（schema 2）。
解析前後の測定値、実行結果（normalized / skipped / analyzed / failed）、
出力検証結果が含まれます。詳細解析は各音声トラックを処理前後に
フルデコードするため、長尺または多トラックの素材では処理時間が増えます。
各ファイルのレコードには、速度変更を行った場合だけ`speedIntermediateProfile`
（採用した中間コーデック・コンテナ・選定理由）が入り、速度変更を行っていない
場合は`null`です。schema 1にあった目標値依存の`TargetOffset`は、目標値と無関係な
数値が誤解を招くため削除しました（`Threshold`は目標非依存のため維持）。
レポートを保存できなかった場合は成功扱いにせず、CLIは終了コード1を返します。

GUIの実行ログは`%APPDATA%\media-normalizer\media-normalizer.log`にも保存されます。
5 MiBに達すると直前ログを`media-normalizer.log.1`へ一世代ローテーションします。

ALACは一般にはM4Aコンテナ（`.m4a`）で利用されます。本アプリは互換性のため
明示的な`.alac`拡張子も入力候補として受け付けます。

## CLI

フォルダ入力:

```powershell
pwsh -File .\media-normalizer.ps1 -Cli `
  -InputPath 'C:\media\input' `
  -OutputDir 'C:\media\output' `
  -Mode both `
  -Preset 'デフォルト' `
  -AudioOutputFormat flac
```

単一音声ファイルの解析のみ:

```powershell
pwsh -File .\media-normalizer.ps1 -Cli `
  -InputFile 'C:\media\sample.wav' `
  -OutputDir 'C:\media\report' `
  -AnalyzeOnly
```

主なオプション:

- `-Mode audio|video|both`
- `-AudioOutputFormat mp3|m4a|aac|flac|wav|opus|ogg`
- `-AnalyzeOnly`
- `-SkipIfNormalized:$false`（既定は有効）
- `-NormalizationTolerance 0.5`
- `-Recurse:$false`（既定は有効）
- `-PreserveHierarchy:$false`（既定は有効）
- `-CollisionPolicy rename|skip|overwrite`
- `-ReportPath <JSONパス>`

存在しないプリセット名は既定値へ黙って置換せず、利用可能な名前を表示して
エラー終了します。

## ラウドネス目標値の範囲

Integrated Loudness（目標LUFS）は`-70.0`〜`-5.0`、True Peakは`-9.0`〜`0.0`の
範囲でのみ指定できます（FFmpeg `loudnorm`フィルタの受理範囲）。GUIの数値入力欄は
この範囲外へ動かせません。`presets.json`に範囲外の値を持つプリセットがあると、
起動時に警告ログを出してそのプリセットを選択肢から除外します（既定プリセットへ
自動的にフォールバックします）。CLIで範囲外プリセットを選択した場合は、範囲を
明示したメッセージとともに終了コード2で終了します。

## プリセットについて

- `放送（EBU R 128）` の -23 LUFS は EBU R 128 の番組ラウドネス基準です。
  True Peak、コーデック、コンテナ等は納品先仕様を優先してください。
- `動画配信（-14 LUFS目安）` は実務上の目安であり、YouTube等の公式納品規格を
  意味しません。サービス側の再生時音量調整と納品要件は変更され得ます。
- `デフォルト` と `ポッドキャスト` も運用上の初期値です。
  配信先が指定する値がある場合は、その値を優先してください。

## 導入・安全再ビルド

このリポジトリからビルドする場合の入口は
`scripts\rebuild-media-normalizer.bat`だけです。このバッチが実行中のWindowsを判定し、
x64またはARM64の適切な配布物を生成します。

引数なしでダブルクリックすると、保存先の親フォルダーを選択できます。
リポジトリルートを選ぶと
`artifacts/media-normalizer-win-<runtime>/`へ生成します。別の親フォルダーを
選ぶと、`<選択先>/MediaNormalizerBuilds/media-normalizer-win-<runtime>/`へ
生成します。単一の既存フォルダーをバッチへドラッグ＆ドロップして指定する
こともできます。ファイル、存在しないパス、複数パスはビルド前に拒否します。

ビルドはアプリを自動起動しません。完了後、生成されたフォルダー内の
`media-normalizer.bat`を実行してください。アーキテクチャを固定する補助BAT
（`scripts\rebuild-media-normalizer-x64.bat`と
`scripts\rebuild-media-normalizer-arm64.bat`）は開発・クロスビルド検証用であり、
通常の導線には使用しません。

各ZIPと同名の`.zip.sha256`に公開用のSHA-256チェックサムが出力されます。
既存の同一バージョン・同一アーキテクチャ配布物がある場合は、manifest、
SHA-256、PEアーキテクチャを再検証して同梱ランタイムを再利用します。利用可能な
配布物もキャッシュもない初回ビルドだけ、固定バージョンの依存物を取得します。

一般公開前など、既存ランタイムや共有キャッシュを一切使わずに取得経路から
検証する場合は、同じ入口へ`--clean`を指定します。

```bat
scripts\rebuild-media-normalizer.bat --clean
scripts\rebuild-media-normalizer.bat --clean "C:\BuildOutput"
```

1つ目は保存先選択画面を表示し、2つ目は指定した既存フォルダーの直下に
`MediaNormalizerBuilds`を作成します。完全クリーンビルドでは、ステージング領域
内に空の隔離キャッシュを作成してFFmpeg、Python、Pythonパッケージをすべて
再取得し、固定SHA-256で検証します。既存の配布物と`.work/portable-cache`は
読み取りも削除もせず、隔離キャッシュはランタイム生成後に削除されるためZIPへ
混入しません。取得は1回900秒で打ち切り、失敗時は追加2回、合計3回まで
再試行します。Windows標準の`curl.exe`を優先して進捗を表示し、利用できない
環境ではPowerShellの取得処理へフォールバックします。すべてのステージング・
検証が成功するまでは既存出力を置換しません。
再ビルドの最終段では`test-artifact-integrity.ps1`がZIP全エントリを読み取り、
危険・重複パス、公開チェックサム、必須ファイル、展開済み成果物とのSHA-256一致、
同梱依存manifestを検証します。このpost-conditionが失敗すると更新をロールバックします。

この再ビルド処理が依存ツールの一括導入・同梱経路です。配布利用者による
個別インストールは不要です。起動時の `runtime-check.bat` は同梱物の
SHA-256、バージョン、必要なFFmpeg機能を検証します。

依存バージョンと取得元は `portable-dependencies.json`、再配布上の注意は
`THIRD-PARTY-NOTICES.md` と `docs/PORTABLE-DISTRIBUTION.md` を参照してください。

## インストーラーパッケージの生成

`installer/Install-MediaNormalizer.ps1` は、`installer/payload/` に置かれた配布ZIPと
`payload-manifest.json` を前提に動作します。このpayloadは生成物のため、リポジトリには
含まれていません。cloneした状態から導入する場合は、先に次を実行してください。

```powershell
pwsh -File .\scripts\build-media-normalizer-installer-package.ps1
```

x64とARM64の配布物を再ビルドし、`installer/payload/` へZIPと、SHA-256・PE
アーキテクチャ・管理対象ファイル一覧を含む `payload-manifest.json` を出力します。
ビルド済み配布物を再利用する場合は `-SkipPortableRebuild`、片方のアーキテクチャだけ
生成する場合は `-Runtime win-x64` のように指定します。

生成後は次で導入・更新を実行します（インストール先の親フォルダーを画面で選択します）。

```powershell
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass `
  -File .\installer\Install-MediaNormalizer.ps1 -SelectOutputRoot
```

payloadが未生成のまま実行した場合は、manifest欠落として
`MEDIA_NORMALIZER_INSTALLER:MANIFEST_INVALID`を表示して停止します。manifestに記載された
対応ZIPだけが欠ける場合は`MEDIA_NORMALIZER_INSTALLER:PAYLOAD_ARCHIVE_MISSING`で停止します。
配布パッケージに同梱される利用者向けの入口BATは配布側のレイアウトに属し、
このリポジトリには含まれません。インストーラーの信頼境界と更新順序は
`installer/README.md` と `docs/installer-architecture.md` を参照してください。

## 公開前の注意

現在のローカル生成物はコード署名されていません。一般公開する場合は、正式な
コード署名、公開チェックサム、FFmpeg等のライセンス表示と対応ソース提供方法を
公開工程として整備してください。

## Overview

Media Normalizerは、Windows上で音声・動画のラウドネス、音声形式、再生速度を
一括調整するPowerShell製ツールです。GUIとCLIを備え、portable packageでは固定済みの
FFmpegとPython runtimeを使用します。

## Requirements

sourceからの実行・再ビルドにはWindows 10/11、PowerShell 7、対応architectureの
FFmpeg・ffprobeが必要です。portable packageは必要なruntimeを同梱し、起動時に
version、SHA-256、必要機能を検証します。

## Installation

利用者向けの導入手順は[起動方法](#起動方法)を参照してください。配布ZIPは
Windows x64用とWindows ARM64用を分けて提供し、展開後はフォルダー全体を保持して
`media-normalizer.bat`を実行します。

配布ZIPとinstaller payloadはいずれも生成物のため、このリポジトリには含まれません。
sourceから導入する場合は[導入・安全再ビルド](#導入安全再ビルド)または
[インストーラーパッケージの生成](#インストーラーパッケージの生成)を実行してください。

## Usage

GUI操作は[GUIの使い方](#guiの使い方)、自動処理や検証用途は[CLI](#cli)を参照して
ください。正規化前に、選択したプリセットと納品先・配信先の要件が一致することを
確認してください。

## Development

再現可能なportable buildは[導入・安全再ビルド](#導入安全再ビルド)に従います。ビルド
入口とビルド補助scriptはすべて`scripts/`配下にあり、リポジトリルートに実行用BATは
置きません。依存versionとSHA-256は`portable-dependencies.json`で固定されています。
公開候補の生成物、テスト結果、ローカル設定、ログはsource repositoryへ含めません。

## Configuration

GUI設定は利用者のローカル`settings.json`に保存されます。このファイルは端末固有情報を
含み得るためsource repositoryには含めません。CLIの入力・出力・preset指定は[CLI](#cli)を
参照してください。

## Uninstall

portable版はMedia Normalizerの展開folderを削除します。installer版はWindowsの
「インストールされているアプリ」からアンインストールしてください。入力メディアと、
利用者が指定した出力folderは自動削除されません。

## Known limitations

GUI、installer、同梱runtimeはWindows専用です。配布ZIPはx64版とARM64版が別です。
生成物は現時点ではコード署名されていないため、公開時はチェックサムと署名状態を明示します。
DRM保護された入力や、同梱FFmpegが対応しないcodecは処理できません。

## Security

脆弱性の可能性がある情報、認証情報、個人情報を含むメディアは公開Issueへ投稿しないで
ください。GitHub repository公開後はGitHub Security Advisoriesの非公開報告機能を
使用してください。同梱実行ファイルと依存packageは、配布manifestおよび起動時診断で
versionとSHA-256を検証します。

## Support

一般的な不具合報告と機能要望は、再現手順、Windows architecture、入力形式、表示された
エラーを添えてGitHub Issuesへ提出してください。著作権で保護された入力メディア、認証情報、
個人情報、設定ファイル全体は添付しないでください。

## License

Media Normalizerの独自source codeは[MIT License](LICENSE)で提供します。portable ZIPに
含まれるFFmpeg、Python、Python packagesには個別のライセンスが適用されます。
再配布条件と対応source情報は[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)および
配布物内のlicense filesを確認してください。MIT Licenseは第三者componentの条件を
置き換えません。
