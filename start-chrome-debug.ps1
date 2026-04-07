#Requires -Version 5.1
# 启动 Chrome 调试模式（用于 OpenClaw 连接）
# 兼容 Windows 10 / 11 (PowerShell 5.1+)
# 单实例：若已有调试 Chrome 则先关闭再重启

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = "Stop"

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "  启动 Chrome 调试模式 (Windows 11)" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan
Write-Host ""

# ─── 查找 Chrome 路径 ────────────────────────────────────────
function Find-Chrome {
    # 优先读取注册表（最可靠）
    $regPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe"
    )
    foreach ($rp in $regPaths) {
        if (Test-Path $rp) {
            $path = (Get-ItemProperty $rp).'(default)'
            if ($path -and (Test-Path $path)) { return $path }
        }
    }
    # 备用常见路径
    $fallbackPaths = @(
        "C:\Program Files\Google\Chrome\Application\chrome.exe",
        "C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
    )
    foreach ($p in $fallbackPaths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# ─── 查找 Chrome 实例 ────────────────────────────────────────
function Get-Procs {
    try {
        $debugProcs = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'remote-debugging-port=9222' }
    } catch {
        $debugProcs = Get-WmiObject Win32_Process | Where-Object { $_.CommandLine -match 'remote-debugging-port=9222' }
    }
    return $debugProcs
}

# ─── 清理已有调试实例 ────────────────────────────────────────
function Stop-ExistingDebugChrome {
    $debugProcs = Get-Procs

    if ($debugProcs) {
        Write-Host "检测到已有调试 Chrome，正在关闭..."
        foreach ($proc in $debugProcs) {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2

        # 二次检查
        $debugProcs = Get-Procs
        if ($debugProcs) {
            Write-Host "普通关闭失败，尝试强制关闭..."
            foreach ($proc in $debugProcs) {
                taskkill /PID $proc.ProcessId /F /T 2>$null
            }
            Start-Sleep -Seconds 1
        }

        # 最终确认
        $stillRunning = Get-Procs
        if ($stillRunning) {
            Write-Host "✗ 无法关闭现有 Chrome，请手动在任务管理器中结束 chrome.exe 进程。" -ForegroundColor Red
            exit 1
        }
        Write-Host "✓ 已关闭" -ForegroundColor Green
    }
}

# ─── 初始化配置 ──────────────────────────────────────────────
$chromePath = Find-Chrome
$userDataDir = "$env:LOCALAPPDATA\Chrome-OpenClaw-Debug"
$logFile = "$env:TEMP\chrome-debug.log"

if (-not $chromePath) {
    Write-Host "✗ 未找到 Chrome，请先安装后重试" -ForegroundColor Red
    Write-Host "  下载: https://www.google.com/chrome/"
    exit 1
}

Write-Host "系统: Windows"
Write-Host "Chrome: $chromePath"
Write-Host "用户数据目录: $userDataDir"
Write-Host ""

# 确保数据目录存在
if (-not (Test-Path $userDataDir)) {
    New-Item -ItemType Directory -Path $userDataDir -Force | Out-Null
}

# 关闭旧实例
Stop-ExistingDebugChrome

# ─── 启动 Chrome ─────────────────────────────────────────────
$chromeArgs = @(
    "--remote-debugging-port=9222",
    "--user-data-dir=`"$userDataDir`"",
    "--log-file=`"$logFile`"",
    "--no-first-run",
    "--no-default-browser-check",
    "--disable-background-networking",
    "--disable-sync",
    "--disable-translate",
    "--disable-features=TranslateUI",
    "--remote-allow-origins=*"
)

Write-Host "正在启动 Chrome 调试模式..."
Write-Host "端口: 9222"
Write-Host ""

$proc = Start-Process -FilePath $chromePath -ArgumentList $chromeArgs -PassThru -WindowStyle Normal
Write-Host "Chrome PID: $($proc.Id)"
Write-Host "Chrome 日志: $logFile"

# ─── 等待启动并验证 ──────────────────────────────────────────
Write-Host "等待 Chrome 启动..."
$success = $false
for ($i = 1; $i -le 15; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "http://127.0.0.1:9222/json/version" -UseBasicParsing -TimeoutSec 2 -ErrorAction Stop
        if ($resp.StatusCode -eq 200) { $success = $true; break }
    } catch {
        # 忽略等待期间的网络错误
    }
    Write-Host -NoNewline "."
    Start-Sleep -Seconds 1
}
Write-Host ""

# ─── 检查结果 ────────────────────────────────────────────────
if ($success) {
    try {
        $json = Invoke-RestMethod -Uri "http://127.0.0.1:9222/json/version" -UseBasicParsing
        $version = $json.Browser
    } catch {
        $version = "未知版本"
    }

    Write-Host "✓ Chrome 调试模式启动成功！" -ForegroundColor Green
    Write-Host ""
    Write-Host "Chrome PID: $($proc.Id)"
    Write-Host "Chrome 版本: $version"
    Write-Host "调试端口: http://127.0.0.1:9222"
    Write-Host "用户数据目录: $userDataDir"
    Write-Host ""
    Write-Host "正在打开各 Web 平台登录页（便于授权）..."

    $webUrls = @(
        "https://claude.ai/new"
        "https://chatgpt.com"
        "https://www.doubao.com/chat/"
        "https://chat.qwen.ai"
        "https://www.kimi.com"
        "https://gemini.google.com/app"
        "https://grok.com"
        "https://chat.deepseek.com/"
        "https://chatglm.cn"
        "https://chat.z.ai/"
        "https://manus.im/app"
    )

    foreach ($url in $webUrls) {
        Start-Process -FilePath $chromePath -ArgumentList "--remote-debugging-port=9222", "--user-data-dir=`"$userDataDir`"", $url -WindowStyle Hidden
        Start-Sleep -Milliseconds 500
    }
    Write-Host "✓ 已打开: Claude, ChatGPT, Doubao, Qwen, Kimi, Gemini, Grok, GLM 等" -ForegroundColor Green
    Write-Host ""
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "下一步操作：" -ForegroundColor Yellow
    Write-Host "==========================================" -ForegroundColor Yellow
    Write-Host "1. 在各标签页中登录需要使用的平台"
    Write-Host "2. 确保 config 中 browser.attachOnly=true 且 browser.cdpUrl=http://127.0.0.1:9222"
    Write-Host "3. 运行 ./onboard.sh webauth 选择对应平台完成授权（将复用此浏览器）"
    Write-Host ""
    Write-Host "停止调试模式："
    Write-Host "  Stop-Process -Name chrome -Force  (或在任务管理器中结束 chrome.exe)"
    Write-Host "==========================================" -ForegroundColor Yellow
} else {
    Write-Host "✗ Chrome 启动失败" -ForegroundColor Red
    Write-Host ""
    Write-Host "请检查："
    Write-Host "  1. Chrome 路径: $chromePath"
    Write-Host "  2. 端口 9222 是否被占用: netstat -ano | findstr :9222"
    Write-Host "  3. 用户数据目录权限: $userDataDir"
    Write-Host "  4. 启动日志: $logFile"
    Write-Host ""
    Write-Host "尝试手动启动："
    Write-Host "  & `"$chromePath`" --remote-debugging-port=9222 --user-data-dir=`"$userDataDir`""
    exit 1
}