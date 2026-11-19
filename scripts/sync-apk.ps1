# 把 GitHub Release 上的安装包同步到本地，保证每次发版后本地都留一份。
#
# 用法：
#   pwsh scripts/sync-apk.ps1              # 同步全部版本
#   pwsh scripts/sync-apk.ps1 -LatestOnly  # 只同步最新一版
#
# 为什么需要脚本：Release 上的包是 CI 产物，本地没有构建环境（无 Flutter SDK / NDK），
# 所以「留一份」只能靠下载。文件已存在且大小一致就跳过，可反复跑。
param(
  [switch]$LatestOnly
)

$ErrorActionPreference = 'Stop'
$env:NO_PROXY = '*'
$env:no_proxy = '*'
$env:HTTP_PROXY = ''
$env:HTTPS_PROXY = ''

$Repo = 'mengxiangbaofu888/fanhuo-reader-20261117'
$OutDir = Join-Path $PSScriptRoot '..\..\..\downloads\fanhuo-reader-20261117\apk'
$OutDir = [System.IO.Path]::GetFullPath($OutDir)
New-Item -ItemType Directory -Force $OutDir | Out-Null

$tokenFile = 'D:\github\downloads\fanqie-reader-20261111\ghh.txt'
if (-not (Test-Path $tokenFile)) {
  throw "找不到 token：$tokenFile"
}
$token = ((Get-Content $tokenFile -Raw) -split "`n")[0] -replace 'Authorization:\s*Bearer\s*', '' -replace '\s', ''
$headers = @{
  Authorization          = "token $token"
  'User-Agent'           = 'dsh'
  'Accept'               = 'application/vnd.github+json'
}

$perPage = if ($LatestOnly) { 1 } else { 100 }
$releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=$perPage" -Headers $headers -NoProxy

$downloaded = 0
$skipped = 0
$failed = @()

foreach ($rel in $releases) {
  foreach ($asset in $rel.assets) {
    if ($asset.name -notlike '*.apk') { continue }
    $dst = Join-Path $OutDir $asset.name
    if ((Test-Path $dst) -and ((Get-Item $dst).Length -eq $asset.size)) {
      $skipped++
      continue
    }
    $ok = $false
    for ($i = 1; $i -le 5; $i++) {
      try {
        $client = [System.Net.Http.HttpClient]::new()
        $client.DefaultRequestHeaders.Add('User-Agent', 'dsh')
        $bytes = $client.GetByteArrayAsync($asset.browser_download_url).Result
        if ($null -eq $bytes -or $bytes.Length -ne $asset.size) { throw '字节数不符' }
        [System.IO.File]::WriteAllBytes($dst, $bytes)
        $ok = $true
        break
      } catch {
        Start-Sleep -Seconds (3 * $i)
      }
    }
    if ($ok) {
      $downloaded++
      Write-Host ("  下载 {0}" -f $asset.name)
    } else {
      $failed += $asset.name
    }
  }
}

$apks = Get-ChildItem $OutDir -Filter *.apk
$totalMb = [math]::Round((($apks | Measure-Object Length -Sum).Sum / 1MB), 0)
Write-Host ""
Write-Host ("本地目录：{0}" -f $OutDir)
Write-Host ("新下载 {0} 个，跳过 {1} 个，共 {2} 个包 / {3} MB" -f $downloaded, $skipped, $apks.Count, $totalMb)
if ($failed.Count -gt 0) {
  Write-Host ("失败：{0}" -f ($failed -join ', '))
  exit 1
}