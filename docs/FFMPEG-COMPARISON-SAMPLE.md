# FFmpeg 比較サンプル資料 (P0-8)

この資料は、Windows固定FFmpegとmacOS arm64固定FFmpegへ**同じ入力ファイル**を渡し、Media Normalizerのreport差を記録するためのスターターキットです。比較許容差は実測前に決めません。

## 含まれるもの

- `tests/support/fixtures/media-normalizer/New-P0ComparisonCorpus.ps1` — 明示したFFmpeg実体から8ファイルのコーパスを一度だけ生成し、入力ごとのbyte lengthとSHA-256を記録します。
- `tests/support/fixtures/media-normalizer/Test-P0ComparisonCorpus.ps1` — 両OSへコピーしたコーパスの欠落・追加・サイズ・SHA-256を検査します。
- `contracts/fixtures/ffmpeg-comparison/p0-8-receipt.template.json` — OSごとのFFmpeg/ffprobe実体・report hash・比較契約を記録する空のreceiptです。数値許容差は未記入です。

## コーパスの内容

| 入力 | 用途 |
| --- | --- |
| `audio-dynamic.wav` | PCM、段階的に音量を変えた合成音 |
| `audio-dynamic.flac` | 同じmasterから作るFLAC |
| `audio-dynamic.mp3` | 同じmasterから作るMP3 |
| `audio-dynamic.m4a` | 同じmasterから作るAAC/M4A |
| `video-basic.mp4` | video 1 stream + audio 1 stream |
| `video-basic.mkv` | 同じ構成のMatroska |
| `video-multistream.mkv` | video、audio 2 stream、字幕、chapter 2件。速度変更拒否とstream検査用 |
| `invalid-corrupt.mp4` | 拡張子は対応形式だが中身は不正。失敗判定の比較用 |

## 生成と配布

P0-8の片側で、固定したFFmpegの**絶対path**を指定して一度だけ生成します。出力先は既存でない専用directoryにしてください。上書きは拒否されます。

```powershell
pwsh -NoLogo -NoProfile -File .\tests\support\fixtures\media-normalizer\New-P0ComparisonCorpus.ps1 `
  -FfmpegPath 'C:\path\to\pinned\ffmpeg.exe' `
  -OutputDirectory 'C:\temp\mn-p0-8-fixtures'
```

できたdirectory全体をもう一方のOSへコピーします。**各OSで生成し直さないでください。** それぞれで検証scriptを実行し、8ファイルのhashがmanifestと一致することを確認します。

```powershell
pwsh -NoLogo -NoProfile -File .\tests\support\fixtures\media-normalizer\Test-P0ComparisonCorpus.ps1 `
  -CorpusDirectory 'C:\temp\mn-p0-8-fixtures'
```

fixtureのmanifestには生成元FFmpegのfile name、SHA-256、version、build configurationが入ります。machine固有の絶対pathは含めません。

## reportの採取

各OSでFFmpegとffprobeの固定実体を環境変数へ指定し、同じrepo revision、preset、target、入力hashで実行します。AnalyzeOnlyでは一度にaudio/videoを混ぜず、fixtureのrecommended modeごとにreportを分けます。

```powershell
$env:FFMPEG_PATH = 'C:\path\to\pinned\ffmpeg.exe'
$env:FFPROBE_PATH = 'C:\path\to\pinned\ffprobe.exe'
$report = 'C:\temp\mn-p0-8-reports\audio-dynamic-flac.audio.json'
pwsh -NoLogo -NoProfile -File .\media-normalizer.ps1 -Cli `
  -InputPath 'C:\temp\mn-p0-8-fixtures\audio-dynamic.flac' `
  -OutputDir 'C:\temp\mn-p0-8-output' -Mode audio -AnalyzeOnly -ReportPath $report
```

macOSでは`FFMPEG_PATH`と`FFPROBE_PATH`に固定したarm64実体を指定し、同じコマンド引数で実行します。video fixtureは`-Mode video -AnalyzeOnly`を使います。`-Mode both -AnalyzeOnly`は現在audio側だけを走らせるため、video比較には使いません。

速度変更拒否と実出力のstream検証はAnalyzeOnlyとは別のrunです。`video-multistream.mkv` に対して専用の空output directoryを使い、速度変更を指定して両OSの拒否結果を確認してください。正常な単一stream videoも別runで通常処理し、reportの`validation`を比較します。出力内容を比較するrunでは、runごとに空の出力先を用意します。

## 比較時の扱い

1. report `schemaVersion`、field集合、summary count、`action`、stream数、離散的なvalidation結果、速度変更拒否結果を完全一致で比較します。
2. `generatedAt`、file path、開始・完了時刻、解析時刻、pathを含むerror文字列を正規化します。
3. `IntegratedLufs`、`TruePeakDbtp`、`LoudnessRangeLu`、`Threshold`の差を測定し、複数fixtureの実測と値の意味を根拠にfield別許容差を提案します。
4. `p0-8-receipt.template.json`へOS、FFmpeg/ffprobeのpath・SHA-256・version・build configuration、fixture manifest hash、report hash、測定差と根拠を記録します。

このkitには実測値も許容差も含めていません。両OSの固定binaryが未実行ならreceiptの`result`は`PENDING`のままとし、P0-8完了やPhase 3着手の根拠にはしません。生成済みメディアとreportにはローカルpathが入る可能性があるため、個人情報を確認せずsource repositoryへ追加しないでください。
