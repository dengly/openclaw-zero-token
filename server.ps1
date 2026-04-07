#!/usr/bin/env pwsh
<#
.SYNOPSIS
    OpenClaw Gateway 服务启动/管理脚本 (兼容 Windows 11 / PowerShell 5.1+)
.DESCRIPTION
    支持 start, stop, restart, status, update-cookie 命令。
    自动处理 Node.js 路径查找、配置初始化、后台运行与日志捕获。
#>
param(
    [Parameter(Position=0)]
    [string]$Action = "start",
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$RemainingArgs
)

$ScriptDir = $PSScriptRoot
$StateDir  = Join-Path $HOME ".openclaw"
$ConfigFile = Join-Path $StateDir "openclaw.json"
$PidFile   = Join-Path $ScriptDir ".gateway.pid"
$Port      = 3001
$LogFile   = Join-Path $ScriptDir "logs\openclaw-upstream.log"

# ─── 工具函数 ────────────────────────────────────────────────

# 查找 Node.js 可执行文件
function Get-NodePath {
    $node = Get-Command node -ErrorAction SilentlyContinue
    if ($node) { return $node.Source }
    $paths = @(
        "$env:PROGRAMFILES\nodejs\node.exe",
        "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $p }
    }
    return $null
}

# 查询占用指定端口的 PID
function Get-PortPid {
    param([int]$Port)
    try {
        # 优先使用 PowerShell 原生网络命令
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
        return $conn.OwningProcess
    } catch {
        # 备用方案：解析 netstat 输出（兼容低权限环境）
        $result = netstat -ano | Select-String ":$Port\s.*LISTENING"
        if ($result) {
            return ($result -split '\s+')[-1]
        }
        return $null
    }
}

# 打开默认浏览器
function Open-Browser {
    param([string]$Url)
    Start-Process $Url
}

# ─── 环境初始化 ──────────────────────────────────────────────

$NodeExe = Get-NodePath
if (-not $NodeExe) {
    Write-Host "✗ 未找到 node，请先安装 Node.js: https://nodejs.org" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $StateDir, (Join-Path $ScriptDir "logs") | Out-Null
$ExampleConfig = Join-Path $ScriptDir ".openclaw-state.example\openclaw.json"
if (-not (Test-Path $ConfigFile)) {
    if (Test-Path $ExampleConfig) {
        Copy-Item $ExampleConfig $ConfigFile
        Write-Host "已从示例复制配置文件: $ExampleConfig -> $ConfigFile"
    } else {
        Set-Content -Path $ConfigFile -Value "{}"
        Write-Host "已创建空配置文件: $ConfigFile（建议从 .openclaw-state.example\openclaw.json 复制完整配置）"
    }
}

# 读取 Token（兼容 jq 的逻辑）
$GatewayToken = ""
if (Test-Path $ConfigFile) {
    try {
        $config = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($config.gateway -and $config.gateway.auth -and $config.gateway.auth.token) {
            $GatewayToken = $config.gateway.auth.token
        }
    } catch {}
}
if (-not $GatewayToken) { $GatewayToken = $env:OPENCLAW_GATEWAY_TOKEN }

# ─── 核心功能 ────────────────────────────────────────────────

function Stop-Gateway {
    if (Test-Path $PidFile) {
        $OldPid = Get-Content $PidFile
        $proc = Get-Process -Id $OldPid -ErrorAction SilentlyContinue
        if ($proc) {
            Write-Host "停止旧进程 (PID: $OldPid)..."
            Stop-Process -Id $OldPid -Force
            Start-Sleep -Seconds 1
        }
        Remove-Item $PidFile -Force
    }
    $PortPid = Get-PortPid -Port $Port
    if ($PortPid) {
        Write-Host "停止占用端口 $Port 的进程 (PID: $PortPid)..."
        Stop-Process -Id $PortPid -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
}

function Start-Gateway {
    $env:OPENCLAW_CONFIG_PATH = $ConfigFile
    $env:OPENCLAW_STATE_DIR   = $StateDir
    $env:OPENCLAW_GATEWAY_PORT= $Port

    Write-Host "系统: Windows 11  |  Node: $(& $NodeExe --version)"
    Write-Host "启动 Gateway 服务..."
    Write-Host "配置文件: $ConfigFile"
    Write-Host "状态目录: $StateDir"
    Write-Host "日志文件: $LogFile"
    Write-Host "端口: $Port"
    Write-Host ""

    # 使用 .NET Process 实现后台运行
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $NodeExe
    $psi.Arguments = "`"$ScriptDir\openclaw.mjs`" gateway --port $Port"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    $process.Start() | Out-Null

    # ✅ 正确方式：使用 add_OutputDataReceived / add_ErrorDataReceived 订阅事件
    $process.add_OutputDataReceived({
        param($sender, $e)
        if ($e.Data) {
            Add-Content -Path $LogFile -Value $e.Data
            Write-Host $e.Data
        }
    })
    $process.add_ErrorDataReceived({
        param($sender, $e)
        if ($e.Data) {
            Add-Content -Path $LogFile -Value $e.Data
            Write-Host $e.Data -ForegroundColor Yellow
        }
    })

    # 开始异步读取输出流
    $process.BeginOutputReadLine()
    $process.BeginErrorReadLine()

    $GatewayPid = $process.Id
    Set-Content -Path $PidFile -Value $GatewayPid
    Write-Host "等待 Gateway 就绪..."

    $WebUiReady = $false
    $i = 0
    while ($i -lt 30) {
        $i++
        try {
            $resp = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/" -TimeoutSec 1 -UseBasicParsing -ErrorAction Stop
            if ($resp.StatusCode -eq 200) {
                Write-Host "Gateway 已就绪 (${i}s)"
                $WebUiReady = $true
                break
            }
        } catch {
            # 连接被拒绝或超时，继续轮询
        }
        # 检查进程是否意外退出
        if ($process.HasExited) {
            Write-Host "Gateway 进程已退出，启动失败" -ForegroundColor Red
            if (Test-Path $LogFile) { Get-Content $LogFile }
            Remove-Item $PidFile -Force
            exit 1
        }
        Start-Sleep -Seconds 1
    }

    if (-not $process.HasExited) {
        if (-not $WebUiReady) {
            Write-Host "⚠ 检测未成功，Gateway 可能尚未就绪，请稍后手动打开 Web UI" -ForegroundColor Yellow
        }
        $WebUiUrl = "http://127.0.0.1:$Port/#token=$GatewayToken"
        Write-Host "Gateway 服务已启动 (PID: $GatewayPid)" -ForegroundColor Green
        Write-Host "Web UI: $WebUiUrl"
        if ($WebUiReady) {
            Write-Host "正在打开浏览器..."
            Open-Browser $WebUiUrl
        } else {
            Write-Host "请手动在浏览器中打开上述地址"
        }
    } else {
        Write-Host "Gateway 服务启动失败，请查看日志:" -ForegroundColor Red
        if (Test-Path $LogFile) { Get-Content $LogFile }
        Remove-Item $PidFile -Force
        exit 1
    }
}

function Update-Cookie {
    param([string]$CookieString)
    if (-not $CookieString) {
        Write-Host "错误：请提供完整的 cookie 字符串" -ForegroundColor Red
        Write-Host "用法: .\server.ps1 update-cookie `"完整的cookie字符串`""
        Write-Host ""
        Write-Host "从浏览器获取 cookie："
        Write-Host "1. 打开 https://claude.ai"
        Write-Host "2. 按 F12 打开开发者工具"
        Write-Host "3. 切换到 Network 标签"
        Write-Host "4. 发送一条消息"
        Write-Host "5. 找到 completion 请求"
        Write-Host "6. 复制 Request Headers 中的完整 cookie 值"
        exit 1
    }

    $match = [regex]::Match($CookieString, 'sessionKey=([^;]+)')
    if (-not $match.Success) {
        Write-Host "错误：cookie 中未找到 sessionKey" -ForegroundColor Red
        exit 1
    }
    $SessionKey = $match.Groups[1].Value

    $AuthFile = Join-Path $StateDir "agents\main\agent\auth-profiles.json"
    if (-not (Test-Path $AuthFile)) {
        Write-Host "错误：auth-profiles.json 不存在，请先运行 ./onboard.ps1" -ForegroundColor Red
        exit 1
    }

    $authData = Get-Content $AuthFile -Raw | ConvertFrom-Json
    $newKeyObj = [PSCustomObject]@{
        sessionKey = $SessionKey
        cookie = $CookieString
        userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    }

    # 安全初始化可能缺失的嵌套节点
    if (-not $authData.PSObject.Properties['profiles']) { $authData | Add-Member -NotePropertyName 'profiles' -NotePropertyValue ([PSCustomObject]@{}) }
    if (-not $authData.profiles.PSObject.Properties['claude-web:default']) { $authData.profiles | Add-Member -NotePropertyName 'claude-web:default' -NotePropertyValue ([PSCustomObject]@{}) }

    $authData.profiles.'claude-web:default'.key = $newKeyObj
    $authData | ConvertTo-Json -Depth 10 | Set-Content $AuthFile

    Write-Host "✓ Claude Web cookie 已更新" -ForegroundColor Green
    $displayKey = if ($SessionKey.Length -gt 50) { $SessionKey.Substring(0, 50) + "..." } else { $SessionKey }
    Write-Host "✓ SessionKey: $displayKey" -ForegroundColor Green
    Write-Host ""
    Write-Host "现在重启服务："
    Write-Host "  .\server.ps1 restart"
}

# ─── 命令入口 ────────────────────────────────────────────────

switch ($Action) {
    "start"         { Stop-Gateway; Start-Gateway }
    "stop"          { Stop-Gateway; Write-Host "Gateway 服务已停止" }
    "restart"       { Stop-Gateway; Start-Gateway }
    "status" {
        if (Test-Path $PidFile) {
            $Pid = Get-Content $PidFile
            $proc = Get-Process -Id $Pid -ErrorAction SilentlyContinue
            if ($proc) {
                Write-Host "Gateway 服务运行中 (PID: $Pid)"
                Write-Host "Web UI: http://127.0.0.1:$Port/#token=$GatewayToken"
            } else {
                Write-Host "Gateway 服务未运行 (PID 文件存在但进程已退出)"
            }
        } else {
            $PortPid = Get-PortPid -Port $Port
            if ($PortPid) {
                Write-Host "端口 $Port 被进程 $PortPid 占用，但不是本脚本启动的 Gateway"
            } else {
                Write-Host "Gateway 服务未运行"
            }
        }
    }
    "update-cookie" { Update-Cookie -CookieString ($RemainingArgs -join " ") }
    default {
        Write-Host "用法: .\server.ps1 {start|stop|restart|status|update-cookie}"
        Write-Host ""
        Write-Host "命令说明："
        Write-Host "  start         - 启动 Gateway 服务"
        Write-Host "  stop          - 停止 Gateway 服务"
        Write-Host "  restart       - 重启 Gateway 服务"
        Write-Host "  status        - 查看服务状态"
        Write-Host "  update-cookie - 更新 Claude Web cookie"
        Write-Host ""
        Write-Host "示例："
        Write-Host '  .\server.ps1 update-cookie "sessionKey=sk-ant-...; anthropic-device-id=..."'
        exit 1
    }
}