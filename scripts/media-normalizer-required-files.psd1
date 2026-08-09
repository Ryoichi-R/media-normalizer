@{
    # media-normalizer 配布パッケージ(ポータブル展開ルート直下)に必須のファイル一覧。
    # TODO.md MN-1 / MN-10, plans/media-normalizer-ui-responsiveness-remediation-plan.md 設計判断12。
    # rebuild-media-normalizer.ps1 のステージング検証と、配布物整合性ゲートの双方から
    # このファイルを単一の定義として読む(行番号にも複製にも依存させない)。
    RequiredRelativePaths = @(
        'MediaNormalizer.exe',
        'media-normalizer.bat',
        'media-normalizer.ps1',
        'diagnose.bat',
        'diagnose.ps1',
        'runtime-env.bat',
        'runtime-check.bat',
        'runtime-check.ps1',
        'THIRD-PARTY-NOTICES.md',
        'README.md',
        'docs\PORTABLE-DISTRIBUTION.md',
        'portable-package.marker',
        'assets\presets.json',
        'lib\MediaNormalizer.Core.psm1',
        'lib\MediaNormalizer.Probe.psm1',
        'lib\MediaNormalizer.Progress.psm1',
        'lib\MediaNormalizer.Ui.psm1',
        'runtime\dependency-manifest.json',
        'runtime\ffmpeg\bin\ffmpeg.exe',
        'runtime\ffmpeg\bin\ffprobe.exe',
        'runtime\python\python.exe',
        'runtime\python\python313.dll'
    )
}
