# OpenClaw onboard 向导启动脚本 (PowerShell 版)
# 适用于 Windows 11
# 注意：若提示执行策略限制，请以管理员身份运行 PowerShell 并执行：
# Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

$ScriptDir = Split-Path -Parent $PSCommandPath
$StateDir  = Join-Path $env:USERPROFILE ".openclaw"
$ConfigFile = Join-Path $StateDir "openclaw.json"

# ─── 检测 Node.js ────────────────────────────────────────────────
$NodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $NodeExe) {
    $FallbackPaths = @(
        "${env:ProgramFiles}\nodejs\node.exe",
        "${env:ProgramFiles(x86)}\nodejs\node.exe",
        "${env:LOCALAPPDATA}\Programs\nodejs\node.exe"
    )
    foreach ($p in $FallbackPaths) {
        if (Test-Path $p) {
            $NodeExe = $p
            break
        }
    }
}

if (-not $NodeExe) {
    Write-Host "✗ 未找到 node，请先安装 Node.js: https://nodejs.org" -ForegroundColor Red
    exit 1
}

$NodeVersion = & $NodeExe --version 2>$null
Write-Host "系统: Windows 11 | Node: $NodeVersion"

# ─── 初始化目录与配置 ─────────────────────────────────────────────
if (-not (Test-Path $StateDir)) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
}

$ExampleConfig = Join-Path $ScriptDir ".openclaw-state.example\openclaw.json"
if (-not (Test-Path $ConfigFile)) {
    if (Test-Path $ExampleConfig) {
        Copy-Item -Path $ExampleConfig -Destination $ConfigFile
        Write-Host "已从示例复制配置文件: $ExampleConfig -> $ConfigFile"
    } else {
        Set-Content -Path $ConfigFile -Value '{}' -Encoding UTF8
        Write-Host "已创建空配置文件: $ConfigFile（建议从 .openclaw-state.example\openclaw.json 复制完整配置）"
    }
}

$env:OPENCLAW_CONFIG_PATH  = $ConfigFile
$env:OPENCLAW_STATE_DIR    = $StateDir
$env:OPENCLAW_GATEWAY_PORT = "3001"

Write-Host "配置文件: $env:OPENCLAW_CONFIG_PATH"
Write-Host "状态目录: $env:OPENCLAW_STATE_DIR"
Write-Host "端口: $env:OPENCLAW_GATEWAY_PORT"
Write-Host ""

# ─── 帮助信息 ────────────────────────────────────────────────────
function Show-Help {
    $ScriptName = Split-Path $PSCommandPath -Leaf
    Write-Host "用法: $ScriptName [命令] [选项]"
    Write-Host ""
    Write-Host "命令:"
    Write-Host "  onboard         启动官方 onboarding 向导（配置端口、token、API key 等）"
    Write-Host "  webauth         启动 Web 模型授权向导（Claude、ChatGPT、DeepSeek 等）"
    Write-Host "  configure       交互式配置向导"
    Write-Host "  gateway         启动 Gateway 服务"
    Write-Host ""
    Write-Host "选项:"
    Write-Host "  -h, --help      显示帮助信息"
    Write-Host ""
    Write-Host "示例:"
    Write-Host "  .\onboard.ps1                 # 显示帮助"
    Write-Host "  .\onboard.ps1 onboard          # 官方 onboarding"
    Write-Host "  .\onboard.ps1 webauth          # Web 模型授权"
    Write-Host "  .\onboard.ps1 configure        # 交互式配置"
}

# ─── 参数处理与运行 ──────────────────────────────────────────────
$Command  = $args[0]
# 安全截取剩余参数（兼容无额外参数时的空数组）
$RestArgs = if ($args.Count -gt 1) { $args[1..($args.Count-1)] } else { @() }

switch ($Command) {
    "-h"      { Show-Help; exit }
    "--help"  { Show-Help; exit }
    ""        { Show-Help; exit }
    "webauth" {
        Write-Host "启动 Web 模型授权向导..."
        Write-Host ""
        Write-Host "⚠️  提示: 确保 Chrome 调试模式已启动 (./start-chrome-debug.bat 或 .ps1)" -ForegroundColor Yellow
        Write-Host ""
        & $NodeExe (Join-Path $ScriptDir "openclaw.mjs") onboard webauth
    }
    "onboard" {
        Write-Host "启动官方 onboard 向导..."
        & $NodeExe (Join-Path $ScriptDir "openclaw.mjs") onboard @RestArgs
    }
    "configure" {
        Write-Host "启动配置向导..."
        & $NodeExe (Join-Path $ScriptDir "openclaw.mjs") configure @RestArgs
    }
    "gateway" {
        Write-Host "启动 Gateway..."
        & $NodeExe (Join-Path $ScriptDir "openclaw.mjs") gateway @RestArgs
    }
    default {
        & $NodeExe (Join-Path $ScriptDir "openclaw.mjs") @args
    }
}