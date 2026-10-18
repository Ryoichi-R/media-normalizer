# コントリビューションガイド

Media Normalizerへの報告と変更提案の方法をまとめます。提出前に本文書と
[README.md](README.md)を確認してください。

## 報告の前に

- 不具合報告と機能要望はGitHub Issuesへ提出してください。
- 脆弱性の可能性がある内容はIssueへ投稿せず、[SECURITY.md](SECURITY.md)の手順に従ってください。
- 著作権で保護された入力メディア、認証情報、個人情報、`settings.json`全体、
  端末固有パスを含むログは添付しないでください。必要な箇所だけを抜粋し、
  ユーザー名やパスはマスクしてください。

## 不具合報告に含める情報

- 再現手順と期待した結果
- Windows versionとarchitecture（x64 / ARM64）
- 入力メディアの形式、長さ、およびコーデック（ファイル自体は不要）
- 使用した導線（GUI / CLI / portable ZIP / インストーラー）
- 表示されたエラーメッセージ（秘密情報を除去したもの）

## 開発環境

- Windows 10以降（x64またはARM64）
- PowerShell 7以降
- Pester 5以降（テスト実行用）
- .NET SDK（`src/MediaNormalizer.Launcher`のビルド用）

portable runtimeの依存versionとSHA-256は`portable-dependencies.json`で固定されています。
これらを手動で差し替えないでください。

## ビルド

再現可能なビルドの入口は次の1つだけです。

```text
scripts\rebuild-media-normalizer.bat
```

実行中のWindowsを判定し、x64またはARM64の配布物を生成します。
`scripts\rebuild-media-normalizer-x64.bat`と`scripts\rebuild-media-normalizer-arm64.bat`は
クロスビルド検証用であり、通常の導線には使用しません。詳細は
[README.md](README.md)の「導入・安全再ビルド」を参照してください。

## テスト

変更に対応するテストを`tests/unit`または`tests/integration`へ追加し、Pesterで実行します。

```powershell
Invoke-Pester -Path tests/unit
```

- Windows専用API（WinForms、System.Drawing、Win32 P/Invoke等）に依存するテストには
  `-Tag 'WindowsOnly'`を付けてください。非Windows環境ではこのタグを除外して実行します。
- モジュールのトップレベルでWindows専用APIやI/Oを実行しないでください。
  非Windows環境で`Import-Module`自体が失敗し、タグでは救済できません。
- 配布物とZIPに関わる変更では、`scripts/test-build-contract.ps1`、
  `scripts/test-artifact-integrity.ps1`、`scripts/test-zip-privacy.ps1`も実行してください。

## コーディング規約

- PowerShellとC#はインデント4スペース、markupは2スペース。
- ファイル名はconfigが`kebab-case`、クラスが`PascalCase`、ローカル変数が`camelCase`。
- 既存ファイルの命名、コメント密度、記述スタイルに合わせてください。

## Pull Request

- 1つのPRは1つの目的に絞り、無関係な整形やリネームを混在させないでください。
- 変更内容、実行した検証コマンド、その結果をPR本文へ記載してください。
- 生成物、テスト結果、ローカル設定、ログはコミットしないでください
  （`.gitignore`で除外済みの対象を再追加しないでください）。
- 秘密情報をコード、テスト、文書、ログへ含めないでください。
- 依存物のversionやSHA-256を変更する場合は、変更理由と検証方法を明記してください。

## ライセンス

Pull Requestを提出することにより、その貢献が[MIT License](LICENSE)の条件で
公開されることに同意したものとみなします。第三者componentのライセンス条件は
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)を参照してください。

## 製品バージョンの更新規則

製品番号の唯一の定義元は、このアプリの `Directory.Build.props` の `Version` です。
OSとx64/ARM64が違っても同じリリースには同じ番号を使います。
機能追加はminor、互換修正はpatch、互換性を壊す変更はmajorを更新し、下位桁は0へ戻します。
0.x期間は、互換修正はpatch、機能追加・互換性破壊はminorとし、破壊内容を明記します。
安定契約の開始を1.0.0とします。現在の1.xから0.xへは戻しません。
同一ソースの再ビルド、別OS/RID向けのビルド、ビルド日時の変化だけでは番号を上げません。

ビルド入口が製品番号、Git短縮ID、未コミット変更の有無、UTCビルド日時、対象RIDを
`build-info.json` に生成します。実行時にGitや開発ソースを問い合わせません。
Git情報を取得できない場合は「不明」とし、未コミット変更ありでも検証用配布物を生成できます。
未コミット変更の判定はリポジトリ全体（非ignoreのuntrackedを含む）が対象です。
インストーラーの `-SkipPortableRebuild` は検証済みpackageをそのまま再梱包します。
ソースを更新した場合は、先にportableを再ビルドしてください。
WindowsのPE版情報を生成するため、Windows配布物はWindows上でビルドします。
macOS CLI packageの生成にも製品情報の評価用の.NET 10 SDKが必要です。
