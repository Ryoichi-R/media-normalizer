# Media Normalizer

## 概要

Media Normalizerは、Windows上で音声・動画のラウドネス、音声形式、再生速度を
一括調整するPowerShell製ツールです。GUIとCLIを備え、portable packageでは固定済みの
FFmpegとPython runtimeを使用します。配布ZIPには動作に必要なruntimeが含まれるため、
利用者がFFmpeg、ffprobe、Pythonを別途インストールしたり、`PATH`を設定したりする
必要はありません。

## 目次

- [概要](#概要)
- [主な機能](#主な機能)
- [動作要件](#動作要件)
- [インストール](#インストール)
- [使用方法](#使用方法)
- [CLI](#cli)
- [ラウドネス目標値の範囲](#ラウドネス目標値の範囲)
- [プリセットについて](#プリセットについて)
- [導入・安全再ビルド](#導入安全再ビルド)
- [インストーラーパッケージの生成](#インストーラーパッケージの生成)
- [公開前の注意](#公開前の注意)
- [開発](#開発)
- [設定](#設定)
- [アンインストール](#アンインストール)
- [既知の制限](#既知の制限)
- [セキュリティ](#セキュリティ)
- [サポート](#サポート)
- [ライセンス](#ライセンス)

## 主な機能

- 音声ファイルを直接入力できます。
  - 音声入力: AAC / AIFF（`.aif` / `.aiff`）/ ALAC / FLAC / M4A / MP3 / OGG / Opus / WAV / WMA
  - 音声抽出の入力: MP4 / MOV / MKV / AVI
  - 動画正規化の入力: MP4 / MOV / MKV（AVIは動画正規化には対応せず、音声抽出のみ）
  - 音声出力: MP3 / M4A / AAC / FLAC / WAV / Opus / OGG
- 「解析のみ」で、各音声トラックのIntegrated Loudness、True Peak、
  Loudness Rangeを測定し、JSONレポートを作成できます。
- 既に目標値の±0.5 LU以内でTrue Peak上限も満たし、同一形式・再生速度100%の
  ファイルは、再圧縮せずバイト列をコピーします。
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

## 動作要件

macOS版はApple Silicon / macOS 15以降を対象とするAvalonia GUIとCLIです。
PowerShell・Python・FFmpegを`.app`に同梱するため、利用時の別途インストールは不要です。
macOS 27のApple Silicon実機で検証しています。macOS 15の実機受入は未実施です。
構築・起動方法は[macOS手順](docs/MACOS-PORT.md#2026-09-29-avalonia-app)を参照してください。


Windows版のGUI/CLIはWindows 10/11と、Windows PowerShell 5.1またはPowerShell 7が
必要です。`media-normalizer.ps1`と診断スクリプトはPowerShell 5.1以上で動作する
よう宣言されています。インストーラーの導入・更新処理もWindows PowerShell 5.1に
対応しています。

Windows PowerShell 5.1ではGUIの非同期プローブにThreadJobモジュールが必要です。
未導入の場合は警告を表示して同期モードへフォールバックします。PowerShell 7.4以降は
ThreadJobが本体に同梱されています。5.1で非同期処理を使用する場合は、必要に応じて
`Install-Module ThreadJob -Scope CurrentUser`で導入してください。

sourceからの再ビルドと依存物の取得にはPowerShell 7（`pwsh`）と.NET 10 SDKが
必要です。対応architectureのFFmpeg・ffprobeはportable packageへ同梱されるため、
配布版の利用者による個別インストールは不要です。

## インストール

1. 使用するWindowsに合うZIPを展開します。
   - 一般的なIntel/AMD搭載PC: `media-normalizer-win-x64.zip`
   - Windows on ARM搭載PC: `media-normalizer-win-arm64.zip`
2. 展開したフォルダ内の `media-normalizer.bat` を実行します。

起動時には内蔵ランタイムの存在、SHA-256、バージョン、必要なFFmpeg機能、
一時フォルダの書込権限と空き容量を自動確認します。問題がある場合はGUIを
起動せず、診断結果を表示します。

`MediaNormalizer.exe`を直接実行することもできます。すでにGUIが起動している状態で
もう一度実行すると、新しい処理は開始せず、既存の画面を復元して前面表示を試みます。
Windowsが前面化を許可しない場合はタスクバーが点滅するため、タスクバー上の
Media Normalizerを選択してください。接続や起動に失敗したというメッセージが表示された
場合は、同じフォルダの`diagnose.bat`を実行して診断結果を確認してください。

引数を付けた起動は既存画面の復元へ変換されません。CLI実行中またはGUI実行中に
別の引数付き起動を行った場合は、従来どおり二重実行を拒否します。

全診断を手動で表示するには `runtime-check.bat` を実行してください。

> `media-normalizer.bat` だけを別の場所へ移動しないでください。
> `runtime`、`lib`、`assets`を含む展開済みフォルダ全体が必要です。

## 使用方法

1. ファイル/フォルダを画面へドロップするか、フォルダ/ファイル選択ボタンで
   入力を指定します。
2. 音声正規化、動画正規化、または両方を選びます。
3. プリセットの根拠表示と現在値を確認します。音声出力形式も選択できます。
4. 必要に応じて「解析のみ」「正規化不要なら再圧縮しない」
   「サブフォルダも再帰検索」「出力に入力階層を維持」を変更します。
5. `[確認]` で対象一覧を確認し、`[実行]` を押します。確認前の未スキャン状態では
   実行できません。スキャン後に入力、モード、出力形式などを変更した場合は、もう一度
   `[確認]` を実行してください。

実行中は画面上部の状態表示に、開始中・処理中・キャンセル中・終了処理中の状態を表示します。
音声と動画を同時に選んだ場合も、1つの処理IDで順番に実行します。`[キャンセル]` は現在の
処理へキャンセルを要求し、外部処理の終了とログの後始末が完了してから待機状態へ戻します。
処理が終了したか判断できない場合も、画面を強制終了せず、実行ログと処理IDを確認してください。

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
- `-InputDir <フォルダ>`（フォルダ入力。`-InputPath`でも指定できます）
- `-InputPath <ファイルまたはフォルダ>`（複数指定可。`-InputFile`は別名です）
- `-AudioOutputFormat mp3|m4a|aac|flac|wav|opus|ogg`
- `-SpeedPercent 50..200`（整数、既定は`100`。100%が等速です）
- `-AnalyzeOnly`
- `-SkipIfNormalized:$false`（既定は有効）
- `-NormalizationTolerance 0.5`
- `-Recurse:$false`（既定は有効）
- `-PreserveHierarchy:$false`（既定は有効）
- `-CollisionPolicy rename|skip|overwrite`
- `-ReportPath <JSONパス>`

速度変更は50〜200%の整数で指定します。字幕またはチャプター付き動画、HDR・
BT.2020・10bit以上の動画は、100%以外を安全のため拒否します。動画の速度変更では、
音声に可逆中間コーデックを使用します。

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
候補フォルダーには、入力スナップショットに結び付いた`build-provenance.json`が入り、
候補外の管理対象ファイルにも同じスナップショットを保存します。候補とZIPは、この
スナップショットおよび全ファイルのSHA-256が一致した場合だけ整合性検証に合格します。
既存の同一バージョン・同一アーキテクチャ配布物がある場合は、manifest、
SHA-256、PEアーキテクチャを再検証して同梱ランタイムを再利用します。利用可能な
配布物もキャッシュもない初回ビルドだけ、固定バージョンの依存物を取得します。
FFmpegはBtbNの保持方針で2年間保存される月末buildへ固定します。直近14件だけが
保存される日次buildや内容が変動する`latest` URLは、再現可能な取得元として使用しません。

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
配布パッケージに同梱される利用者向けの入口BATは、リポジトリ内の
`scripts/package-templates/media-normalizer.bat`を元にビルド時に配布物ルートへ生成します。
テンプレート自体はこのリポジトリに含まれます。インストーラーの信頼境界と更新順序は
`installer/README.md` と `docs/installer-architecture.md` を参照してください。

## 公開前の注意

現在のローカル生成物はコード署名されていません。一般公開する場合は、正式な
コード署名、公開チェックサム、FFmpeg等のライセンス表示と対応ソース提供方法を
公開工程として整備してください。

## 開発

再現可能なportable buildは[導入・安全再ビルド](#導入安全再ビルド)に従います。ビルド
入口とビルド補助scriptはすべて`scripts/`配下にあり、リポジトリルートに実行用BATは
置きません。依存versionとSHA-256は`portable-dependencies.json`で固定されています。
公開候補の生成物、テスト結果、ローカル設定、ログはsource repositoryへ含めません。

## 設定

GUI設定は利用者のローカル`settings.json`に保存されます。このファイルは端末固有情報を
含み得るためsource repositoryには含めません。CLIの入力・出力・preset指定は[CLI](#cli)を
参照してください。

## アンインストール

portable版はMedia Normalizerの展開folderを削除します。installer版はWindowsの
「インストールされているアプリ」からアンインストールしてください。入力メディアと、
利用者が指定した出力folderは自動削除されません。

## 既知の制限

Windows版は既存WinForms GUIとinstallerを維持し、x64/ARM64を別々に構築します。
macOS版はApple Silicon専用の`.app`です。Intel MacとmacOS installerは対象外です。
macOS成果物はローカルのad-hoc署名で、Developer ID署名・公証は行っていません。
Finder/Dock経由の最小化解除・前面化の目視受入とWindows非回帰検査は未完了です。
Windows/macOS間の数値比較は今回の実装範囲から除外しています。
DRM保護された入力や、同梱FFmpegが対応しないcodecは処理できません。

## セキュリティ

脆弱性の可能性がある情報、認証情報、個人情報を含むメディアは公開Issueへ投稿しないで
ください。GitHub repository公開後はGitHub Security Advisoriesの非公開報告機能を
使用してください。同梱実行ファイルと依存packageは、配布manifestおよび起動時診断で
versionとSHA-256を検証します。

## サポート

一般的な不具合報告と機能要望は、再現手順、Windows architecture、入力形式、表示された
エラーを添えてGitHub Issuesへ提出してください。著作権で保護された入力メディア、認証情報、
個人情報、設定ファイル全体は添付しないでください。

## ライセンス

Media Normalizerの独自source codeは[MIT License](LICENSE)で提供します。portable ZIPに
含まれるFFmpeg、Python、Python packagesには個別のライセンスが適用されます。
再配布条件と対応source情報は[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)および
配布物内のlicense filesを確認してください。MIT Licenseは第三者componentの条件を
置き換えません。
