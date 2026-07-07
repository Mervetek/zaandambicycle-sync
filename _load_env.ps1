# sync.env'i process $env: ortam degiskenlerine yukler.
# Yerelde: $PSScriptRoot\sync.env dosyasindan. GitHub Actions'ta: workflow sync.env'i Secret'tan olusturur.
# -cmatch sart: Turkce kulturde [A-Z] araligi 'I' harfini eslemez (I->i donusumu); anahtar adlari icin cmatch kullan.
$envFile = Join-Path $PSScriptRoot "sync.env"
if (Test-Path $envFile) {
    Get-Content $envFile | ForEach-Object {
        if ($_ -cmatch '^([A-Z_]+)=(.*)$') {
            [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2].Trim(), 'Process')
        }
    }
}
