# 仅为本次启动的 Codex 进程启用已有代理，不修改系统代理或用户环境变量。
[CmdletBinding()]
param(
    [switch]$CheckOnly,
    [switch]$Restart
)

$ErrorActionPreference = 'Stop'

function Get-ExistingHttpsProxy {
    foreach ($scope in @('Process', 'User')) {
        foreach ($name in @('HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy')) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $proxyUri = $null
                if ([Uri]::TryCreate($value, [UriKind]::Absolute, [ref]$proxyUri) -and
                    $proxyUri.Scheme -in @('http', 'https')) {
                    return $value
                }
            }
        }
    }

    $settings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    if ($settings.ProxyEnable -ne 1 -or [string]::IsNullOrWhiteSpace($settings.ProxyServer)) {
        throw '没有发现已启用的 HTTP/HTTPS 代理，未启动 Codex。'
    }
    $server = [string]$settings.ProxyServer
    if ($server.Contains('=')) {
        $entries = @{}
        foreach ($entry in $server.Split(';')) {
            $pair = $entry.Split('=', 2)
            if ($pair.Count -eq 2) { $entries[$pair[0].Trim()] = $pair[1].Trim() }
        }
        if ($entries.ContainsKey('https')) { $server = $entries['https'] }
        elseif ($entries.ContainsKey('http')) { $server = $entries['http'] }
        else { throw '现有系统代理未提供 HTTP/HTTPS 代理地址。' }
    }
    if ($server -notmatch '^https?://') { $server = 'http://' + $server }
    return $server
}

$package = Get-AppxPackage -Name 'OpenAI.Codex' | Select-Object -First 1
if ($null -eq $package) { throw '未找到当前用户安装的 OpenAI.Codex。' }
$executable = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
    throw '当前 Codex 安装包中没有找到 ChatGPT.exe。'
}
$proxy = Get-ExistingHttpsProxy
$proxyUri = [Uri]$proxy
$mainProcesses = @(Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" |
    Where-Object {
        $_.ExecutablePath -eq $executable -and $_.CommandLine -notmatch '--type='
    })

if ($CheckOnly) {
    [pscustomobject]@{
        模式 = '只读检查：未关闭、启动或修改任何应用'
        应用版本 = [string]$package.Version
        程序路径 = $executable
        现有主进程 = @($mainProcesses.ProcessId)
        代理地址 = '{0}://{1}:{2}' -f $proxyUri.Scheme, $proxyUri.Host, $proxyUri.Port
        启动变量 = 'NODE_USE_ENV_PROXY=1'
        持久环境变量修改 = $false
    } | ConvertTo-Json -Depth 3
    return
}

if ($mainProcesses.Count -gt 0 -and -not $Restart) {
    throw 'Codex 仍在运行。请先完全退出；需要脚本重启时，确认可以中断正在运行的聊天后使用 -Restart。'
}

if ($Restart) {
    foreach ($mainProcess in $mainProcesses) {
        # 再次核对进程路径，避免因进程编号复用而结束其他程序。
        $current = Get-CimInstance Win32_Process -Filter ('ProcessId=' + $mainProcess.ProcessId)
        if ($null -ne $current -and $current.ExecutablePath -eq $executable) {
            Stop-Process -Id $current.ProcessId -Force
            Wait-Process -Id $current.ProcessId -Timeout 15 -ErrorAction SilentlyContinue
        }
    }
    Start-Sleep -Seconds 2
}

$previousEnvironment = @{}
foreach ($name in @('NODE_USE_ENV_PROXY', 'HTTPS_PROXY')) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    [Environment]::SetEnvironmentVariable('NODE_USE_ENV_PROXY', '1', 'Process')
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', $proxy, 'Process')
    $launched = Start-Process -FilePath $executable -PassThru
    Write-Output ('已启动 Codex，进程编号：{0}；已为该进程启用现有代理。' -f $launched.Id)
} finally {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
}
