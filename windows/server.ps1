# Gemini 對話台 — Windows 本機伺服器
# 只用 Windows 內建的 PowerShell（5.1 以上），不需要安裝任何東西。
# 提供對話台網頁，以及「程式代理」需要的本機功能：讀寫檔案、搜尋、執行指令、選擇資料夾。
# 只接受本機（localhost）連線，且每個請求都要帶啟動時產生的權杖。

$ErrorActionPreference = 'Stop'
$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Port  = 8765
$Url   = "http://localhost:$Port/"
$Token = [guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N')
$Utf8  = New-Object System.Text.UTF8Encoding($false)
$OnWindows = ($PSVersionTable.PSEdition -ne 'Core') -or $IsWindows
$Shell = if ($OnWindows) { 'powershell.exe' } else { 'pwsh' }
$Skip  = @('node_modules', '.git', '.svn', '.hg', '__pycache__', '.venv', 'venv', '.next', 'dist', 'build', '.idea', '.vs')
$Bg    = @{}

function Open-UI {
  $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
  # 用 Edge 的「應用程式模式」開成獨立視窗；沒有 Edge 就用預設瀏覽器
  if ($edge) { Start-Process $edge -ArgumentList "--app=$Url" } else { Start-Process $Url }
}

# 已經在執行的話，直接開視窗就好
try {
  $r = Invoke-WebRequest -UseBasicParsing -Uri ($Url + 'api/hello') -TimeoutSec 2
  if ($r.StatusCode -eq 200) { Open-UI; exit }
} catch { }

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add($Url)
try { $Listener.Start() } catch {
  Write-Host "無法使用連接埠 $Port：$($_.Exception.Message)" -ForegroundColor Red
  Write-Host '可能有其他程式正在使用它。關掉其他「Gemini 對話台」視窗後再試一次。'
  Read-Host '按 Enter 結束'
  exit 1
}

function Send($ctx, [int]$code, $obj, [string]$type) {
  $res = $ctx.Response
  if ($obj -is [string]) { $body = $obj } else { $body = ConvertTo-Json -InputObject $obj -Depth 8 -Compress }
  if (-not $type) { $type = 'application/json; charset=utf-8' }
  $bytes = $Utf8.GetBytes($body)
  $res.StatusCode = $code
  $res.ContentType = $type
  $res.Headers['Cache-Control'] = 'no-store'
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}

# 把相對路徑解析到工作資料夾裡；超出工作資料夾就拒絕
function Resolve-In([string]$root, [string]$p) {
  if (-not $root) { throw '尚未選擇工作資料夾。' }
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
  if (-not [IO.Directory]::Exists($rootFull)) { throw "工作資料夾不存在：$rootFull" }
  if (-not $p) { $p = '.' }
  if ([IO.Path]::IsPathRooted($p)) { $full = [IO.Path]::GetFullPath($p) }
  else { $full = [IO.Path]::GetFullPath([IO.Path]::Combine($rootFull, $p)) }
  $full = $full.TrimEnd('\', '/')
  $sep = [string][IO.Path]::DirectorySeparatorChar
  $inside = $full.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($rootFull + $sep, [StringComparison]::OrdinalIgnoreCase)
  if (-not $inside) { throw "路徑超出工作資料夾：$p" }
  return $full
}
function Rel([string]$root, [string]$full) {
  $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
  if ($full.Length -le $rootFull.Length) { return '.' }
  return $full.Substring($rootFull.Length + 1).Replace('\', '/')
}

# 逐層走訪資料夾（略過 node_modules、.git 等），最多 $max 項
function Walk([string]$dir, [bool]$filesOnly, [int]$max) {
  $out = New-Object System.Collections.Generic.List[object]
  $queue = New-Object System.Collections.Generic.Queue[string]
  $queue.Enqueue($dir)
  $truncated = $false
  while ($queue.Count -gt 0) {
    $d = $queue.Dequeue()
    $items = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue | Sort-Object -Property @{Expression = { -not $_.PSIsContainer } }, Name)
    foreach ($it in $items) {
      if ($it.PSIsContainer) {
        if ($Skip -contains $it.Name) { continue }
        $queue.Enqueue($it.FullName)
        if (-not $filesOnly) { $out.Add($it) }
      } else { $out.Add($it) }
      if ($out.Count -ge $max) { $truncated = $true; break }
    }
    if ($truncated) { break }
  }
  return @{ items = $out; truncated = $truncated }
}

function Read-Text([string]$path) {
  $bytes = [IO.File]::ReadAllBytes($path)
  if ($bytes.Length -gt 3000000) { throw '檔案太大（超過 3 MB），請改用 search 找需要的部分。' }
  $n = [Math]::Min($bytes.Length, 8000)
  for ($i = 0; $i -lt $n; $i++) { if ($bytes[$i] -eq 0) { throw '這看起來是二進位檔，無法以文字讀取。' } }
  return $Utf8.GetString($bytes).TrimStart([char]0xFEFF)
}

function Run-Command($b) {
  $root = Resolve-In $b.root '.'
  $cwd = Resolve-In $b.root $b.cwd
  $prefix = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference=''SilentlyContinue''' + "`n"
  if ($b.background) {
    $id = [string]($Bg.Count + 1)
    $log = Join-Path ([IO.Path]::GetTempPath()) ("gemini-harness-bg-" + $id + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.log')
    $script = $prefix + "& { " + $b.command + " } *>&1 | Out-File -FilePath '" + $log.Replace("'", "''") + "' -Encoding utf8"
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    $p = Start-Process -FilePath $Shell -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc" -WorkingDirectory $cwd -WindowStyle Hidden -PassThru
    $Bg[$id] = @{ proc = $p; log = $log }
    return @{ id = $id }
  }
  $timeout = 120
  if ($b.timeout_sec) { $timeout = [Math]::Min(600, [Math]::Max(5, [int]$b.timeout_sec)) }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Shell
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($prefix + $b.command))
  $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
  $psi.WorkingDirectory = $cwd
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.RedirectStandardInput = $true
  $psi.StandardOutputEncoding = $Utf8
  $psi.StandardErrorEncoding = $Utf8
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()
  $o = $p.StandardOutput.ReadToEndAsync()
  $e = $p.StandardError.ReadToEndAsync()
  $timedOut = $false
  if (-not $p.WaitForExit($timeout * 1000)) {
    $timedOut = $true
    if ($OnWindows) { & taskkill.exe /T /F /PID $p.Id 2>$null | Out-Null } else { $p.Kill() }
    $p.WaitForExit(5000) | Out-Null
  }
  $stdout = ''; $stderr = ''
  if ($o.Wait(5000)) { $stdout = $o.Result }
  if ($e.Wait(5000)) { $stderr = $e.Result }
  $code = -1; if ($p.HasExited) { $code = $p.ExitCode }
  # 把 PowerShell 錯誤訊息裡的 CLIXML 雜訊清掉
  if ($stderr.StartsWith('#< CLIXML')) { $stderr = ([regex]::Matches($stderr, '<S S="Error">(.*?)</S>') | ForEach-Object { $_.Groups[1].Value.Replace('_x000D__x000A_', "`n") }) -join '' }
  return @{ stdout = $stdout; stderr = $stderr; exit_code = $code; timed_out = $timedOut }
}

function Handle($ctx) {
  $req = $ctx.Request
  $path = $req.Url.AbsolutePath
  if ($req.HttpMethod -eq 'GET') {
    if ($path -eq '/api/hello') { Send $ctx 200 @{ ok = $true }; return }
    if ($path -eq '/' -or $path -eq '/index.html') {
      $html = [IO.File]::ReadAllText((Join-Path $Here 'index.html'), $Utf8)
      $homeJson = ConvertTo-Json -InputObject ([string]$env:USERPROFILE) -Compress
      $inject = "<script>window.GH_LOCAL={token:'$Token',home:$homeJson,port:$Port};</script>"
      $i = $html.IndexOf('</head>')
      if ($i -ge 0) { $html = $html.Substring(0, $i) + $inject + $html.Substring($i) }
      Send $ctx 200 $html 'text/html; charset=utf-8'
      return
    }
    $file = Join-Path $Here ($path.TrimStart('/').Replace('/', '\'))
    $name = [IO.Path]::GetFileName($file)
    if (@('manifest.webmanifest', 'icon-180.png', 'icon-192.png', 'icon-512.png') -contains $name -and (Test-Path -LiteralPath $file)) {
      $types = @{ '.png' = 'image/png'; '.webmanifest' = 'application/manifest+json' }
      $bytes = [IO.File]::ReadAllBytes($file)
      $res = $ctx.Response; $res.ContentType = $types[[IO.Path]::GetExtension($file)]; $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length); $res.OutputStream.Close(); return
    }
    Send $ctx 404 @{ error = '找不到' }
    return
  }
  if ($req.HttpMethod -ne 'POST') { Send $ctx 405 @{ error = '不支援的方法' }; return }
  # 只接受這個視窗自己發出的請求：權杖必須正確，來源必須是本機網址
  if ($req.Headers['X-GH-Token'] -ne $Token) { Send $ctx 403 @{ error = '權杖錯誤，請重新整理頁面。' }; return }
  $origin = $req.Headers['Origin']
  if ($origin -and $origin -ne "http://localhost:$Port" -and $origin -ne "http://127.0.0.1:$Port") { Send $ctx 403 @{ error = '拒絕來自其他網站的請求。' }; return }
  $sr = New-Object System.IO.StreamReader($req.InputStream, $Utf8)
  $raw = $sr.ReadToEnd(); $sr.Close()
  if ($raw) { $b = ConvertFrom-Json $raw } else { $b = New-Object psobject }

  switch ($path) {
    '/api/ping' { Send $ctx 200 @{ ok = $true; home = $env:USERPROFILE } }
    '/api/pickdir' {
      Add-Type -AssemblyName System.Windows.Forms
      $d = New-Object System.Windows.Forms.FolderBrowserDialog
      $d.Description = '選擇程式代理的工作資料夾'
      $d.ShowNewFolderButton = $true
      if ($b.start -and (Test-Path -LiteralPath $b.start)) { $d.SelectedPath = $b.start }
      $owner = New-Object System.Windows.Forms.Form
      $owner.TopMost = $true; $owner.ShowInTaskbar = $false; $owner.WindowState = 'Minimized'
      $owner.Show(); $owner.Hide()
      $result = $d.ShowDialog($owner)
      $owner.Dispose()
      if ($result -eq [System.Windows.Forms.DialogResult]::OK) { Send $ctx 200 @{ path = $d.SelectedPath } } else { Send $ctx 200 @{ path = '' } }
    }
    '/api/open' {
      $full = Resolve-In $b.root $b.path
      Invoke-Item -LiteralPath $full
      Send $ctx 200 @{ ok = $true }
    }
    '/api/list' {
      $full = Resolve-In $b.root $b.path
      if (-not [IO.Directory]::Exists($full)) { throw "找不到資料夾：$($b.path)" }
      $entries = @()
      if ($b.recursive) {
        $w = Walk $full $false 800
        foreach ($it in $w.items) { $t = 'file'; if ($it.PSIsContainer) { $t = 'dir' }; $entries += @{ name = (Rel $b.root $it.FullName); type = $t } }
        Send $ctx 200 @{ entries = $entries; truncated = $w.truncated }
      } else {
        $items = @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue | Sort-Object -Property @{Expression = { -not $_.PSIsContainer } }, Name | Select-Object -First 500)
        foreach ($it in $items) { $t = 'file'; if ($it.PSIsContainer) { $t = 'dir' }; $entries += @{ name = (Rel $b.root $it.FullName); type = $t } }
        Send $ctx 200 @{ entries = $entries; truncated = ($items.Count -ge 500) }
      }
    }
    '/api/read' {
      $full = Resolve-In $b.root $b.path
      if (-not [IO.File]::Exists($full)) { throw "找不到檔案：$($b.path)" }
      $text = Read-Text $full
      $lines = $text -split "`r?`n"
      $total = $lines.Count
      $start = 1; if ($b.offset) { $start = [Math]::Max(1, [int]$b.offset) }
      $limit = 2000; if ($b.limit) { $limit = [Math]::Max(1, [int]$b.limit) }
      $end = [Math]::Min($total, $start + $limit - 1)
      $content = ''
      if ($start -le $total) { $content = ($lines[($start - 1)..($end - 1)]) -join "`n" }
      if ($content.Length -gt 200000) { $content = $content.Substring(0, 200000); $end = $start + ($content -split "`n").Count - 1 }
      Send $ctx 200 @{ content = $content; start = $start; end = $end; total = $total }
    }
    '/api/write' {
      $full = Resolve-In $b.root $b.path
      $created = -not [IO.File]::Exists($full)
      $dir = [IO.Path]::GetDirectoryName($full)
      if (-not [IO.Directory]::Exists($dir)) { [IO.Directory]::CreateDirectory($dir) | Out-Null }
      $content = [string]$b.content
      [IO.File]::WriteAllText($full, $content, $Utf8)
      Send $ctx 200 @{ ok = $true; created = $created; bytes = $Utf8.GetByteCount($content) }
    }
    '/api/edit' {
      $full = Resolve-In $b.root $b.path
      if (-not [IO.File]::Exists($full)) { throw "找不到檔案：$($b.path)" }
      $text = Read-Text $full
      $old = [string]$b.old_text; $new = [string]$b.new_text
      if (-not $old) { throw 'old_text 不能是空的。' }
      # 檔案用 CRLF 換行時，把模型給的 LF 轉成 CRLF 再比對
      if ($text.IndexOf($old, [StringComparison]::Ordinal) -lt 0 -and $text.Contains("`r`n")) { $old = $old.Replace("`r`n", "`n").Replace("`n", "`r`n"); $new = $new.Replace("`r`n", "`n").Replace("`n", "`r`n") }
      $count = 0; $i = 0
      while (($i = $text.IndexOf($old, $i, [StringComparison]::Ordinal)) -ge 0) { $count++; $i += $old.Length }
      if ($count -eq 0) { throw '在檔案中找不到 old_text，請先用 read_file 確認目前內容（空白與縮排要完全一致）。' }
      if ($count -gt 1 -and -not $b.replace_all) { throw "old_text 在檔案中出現 $count 次，請加入更多前後文讓它唯一，或設定 replace_all。" }
      if ($b.replace_all) { $text = $text.Replace($old, $new) }
      else { $j = $text.IndexOf($old, [StringComparison]::Ordinal); $text = $text.Substring(0, $j) + $new + $text.Substring($j + $old.Length) }
      [IO.File]::WriteAllText($full, $text, $Utf8)
      $n = 1; if ($b.replace_all) { $n = $count }
      Send $ctx 200 @{ ok = $true; replacements = $n }
    }
    '/api/search' {
      $full = Resolve-In $b.root $b.path
      try { $rx = New-Object System.Text.RegularExpressions.Regex($b.pattern, 'IgnoreCase') }
      catch { $rx = New-Object System.Text.RegularExpressions.Regex([regex]::Escape($b.pattern), 'IgnoreCase') }
      $files = @()
      if ([IO.File]::Exists($full)) { $files = @(Get-Item -LiteralPath $full) } else { $files = @((Walk $full $true 5000).items) }
      $hits = New-Object System.Collections.Generic.List[string]
      $truncated = $false
      foreach ($f in $files) {
        if ($b.include -and -not ($f.Name -like $b.include)) { continue }
        if ($f.Length -gt 1500000) { continue }
        try { $text = Read-Text $f.FullName } catch { continue }
        $ln = 0
        foreach ($line in ($text -split "`r?`n")) {
          $ln++
          if ($rx.IsMatch($line)) {
            $t = $line.Trim(); if ($t.Length -gt 220) { $t = $t.Substring(0, 220) + '…' }
            $hits.Add((Rel $b.root $f.FullName) + ':' + $ln + ': ' + $t)
            if ($hits.Count -ge 200) { $truncated = $true; break }
          }
        }
        if ($truncated) { break }
      }
      Send $ctx 200 @{ matches = @($hits); truncated = $truncated }
    }
    '/api/find' {
      $full = Resolve-In $b.root $b.path
      $pat = [string]$b.pattern
      $out = @(); $w = Walk $full $true 20000
      foreach ($f in $w.items) { if ($f.Name -like $pat -or (Rel $b.root $f.FullName) -like $pat) { $out += (Rel $b.root $f.FullName); if ($out.Count -ge 300) { break } } }
      Send $ctx 200 @{ files = $out; truncated = ($out.Count -ge 300) }
    }
    '/api/run' { Send $ctx 200 (Run-Command $b) }
    '/api/bg' {
      $t = $Bg[[string]$b.id]
      if (-not $t) { throw "找不到背景工作 $($b.id)。" }
      if ($b.action -eq 'stop' -and -not $t.proc.HasExited) {
        if ($OnWindows) { & taskkill.exe /T /F /PID $t.proc.Id 2>$null | Out-Null } else { $t.proc.Kill() }
        Start-Sleep -Milliseconds 300
      }
      $text = ''
      if (Test-Path -LiteralPath $t.log) {
        $fs = New-Object System.IO.FileStream($t.log, 'Open', 'Read', 'ReadWrite')
        $rd = New-Object System.IO.StreamReader($fs, $Utf8); $text = $rd.ReadToEnd(); $rd.Close()
        if ($text.Length -gt 20000) { $text = '…' + $text.Substring($text.Length - 20000) }
      }
      Send $ctx 200 @{ running = (-not $t.proc.HasExited); output = $text }
    }
    default { Send $ctx 404 @{ error = '找不到這個功能。' } }
  }
}

Clear-Host
Write-Host ''
Write-Host '  Gemini 對話台（Windows 本機版）已啟動' -ForegroundColor Cyan
Write-Host "  網址：$Url"
Write-Host '  關閉這個視窗就會停止。程式代理執行的指令會記錄在下方。'
Write-Host ''
Open-UI

while ($Listener.IsListening) {
  $ctx = $Listener.GetContext()
  try {
    if ($ctx.Request.Url.AbsolutePath -eq '/api/run') { Write-Host ('  > ' + (Get-Date -Format 'HH:mm:ss') + '  執行指令') -ForegroundColor DarkGray }
    Handle $ctx
  } catch {
    $msg = $_.Exception.Message
    try { Send $ctx 400 @{ error = $msg } } catch { }
  }
}
