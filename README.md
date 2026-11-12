# Windows 上 Dot 无法读取、控制 Codex 原生聊天：环境代理启动修复

本仓库记录一例已通过验收的 Windows 修复：为 Codex 桌面进程设置 `NODE_USE_ENV_PROXY=1` 和已有 HTTP/HTTPS 代理，然后完整退出并重新启动，恢复了 Dot 对已有原生聊天的读取、发送指令和完成结果回读。

这是针对已定位的代理连接问题的启动方案，不是所有 `DesktopThreadReadUnavailableError` 的通用修复，也不是官方补丁。本仓库提供 PowerShell 脚本和案例说明，不包含 Codex 安装程序。

## 测试环境

| 项目 | 本次版本 |
| --- | --- |
| 操作系统 | Windows |
| 桌面安装包 | 26.1106.6628.0 |
| codex-app-tools 插件 | 26.1106.51428 |
| 随应用安装的 Node | v24.22.1 |
| 验收日期 | 2026-11-12，北京时间 UTC+8 |

## 故障与定位

Dot 读取已有 Windows 原生聊天曾返回 `DesktopThreadReadUnavailableError`，后续一次原生读取长时间等待。读取云端持久任务成功、SSH 登录成功不能证明这条原生路径可用。

本地检查结果：

1. 本地 `read_thread` 可以读取同一已有原生聊天。
2. 本地后台和执行器使用相同的正常配置目录，没有发现双配置目录错配。
3. 官方插件查询显示原生插件已安装、启用；执行器的 `server.mjs` 与安装缓存校验值一致。
4. 桌面连接 `codex-cloud-backend.chatgpt.com` 的 WebSocket 反复出现 `ECONNRESET` 或超时。
5. 桌面进程已有代理地址，但缺少 `NODE_USE_ENV_PROXY`。检查该安装版本的 `WebsocketTransport.connect`，其仅在 `process.env.NODE_USE_ENV_PROXY === "1"` 时，为该连接创建使用 `proxyEnv: process.env` 的 HTTP/HTTPS Agent。
6. 使用随应用安装的 Node 做无身份凭据连接对照：默认 HTTPS Agent 返回 `ECONNRESET`，使用已有代理的 Agent 收到 HTTP 401。此处 401 仅证明网络、TLS 和服务器可达，不代表登录成功。

这些证据定位了本机云端连接的代理使用问题；未把不同读取接口的报错都归因于同一个原因。

## 使用方法

### 1. 检查已有代理与安装包

下载或克隆本仓库，打开 PowerShell，在仓库目录运行：

```powershell
& '.\启动Codex代理.ps1' -CheckOnly
```

只读检查会显示应用版本、程序路径、已有主进程、脱敏代理地址以及将使用的开关；不会关闭或启动应用。

脚本查找当前用户的 `OpenAI.Codex` 安装包及 `app\ChatGPT.exe`。代理读取顺序为当前进程环境、当前用户环境、已启用的 Windows HTTP/HTTPS 系统代理。不自动安装代理，也不支持仅提供 PAC 或 SOCKS 地址的配置。

若自动检测不到代理，可先在当前 PowerShell 提供你自己已有的可用 HTTP/HTTPS 代理地址。例如下面只是格式示例，须将端口替换为真实值：

```powershell
$env:HTTPS_PROXY = 'http://127.0.0.1:你的端口'
& '.\启动Codex代理.ps1' -CheckOnly
```

不要在公开反馈中粘贴包含用户名、密码的代理 URL。脚本只读输出只显示代理协议、主机和端口。

### 2. 完整退出并启动

结束正在运行的任务，完全退出桌面程序，然后在同一个 PowerShell 运行：

```powershell
& '.\启动Codex代理.ps1'
```

如果桌面仍运行，无参数模式会拒绝继续。另有显式重启模式：

```powershell
& '.\启动Codex代理.ps1' -Restart
```

`-Restart` 会强制结束匹配当前安装包路径的桌面主进程并重启，可能中断正在执行的聊天和工具调用；仅在可以中断时使用。执行前会再次核对进程路径。

脚本临时设置当前进程的 `NODE_USE_ENV_PROXY=1` 和 `HTTPS_PROXY`，启动桌面程序使其继承，再在 `finally` 中恢复脚本原有环境。它不修改永久用户环境变量、系统代理、程序文件、聊天数据库或权限。

本次 Windows PowerShell 5.1 语法解析及 `-CheckOnly` 检查通过；实际启动、读取和发送验收见下文。脚本采用 UTF-8 BOM，兼容 Windows PowerShell 5.1 的中文读取。

### 3. 从实际 Dot 调用端验收

重连可能生成新的环境 ID。重新列出环境并选择当前在线的正确 Windows，再使用工具发现确认原生工具可用。

1. 调用原生 `read_thread`：`hostId="local"`，`threadId` 填已有测试聊天，`turnLimit=1`，`includeOutputs=false`；核对返回聊天 ID。
2. 向同一测试聊天调用原生 `send_message_to_thread`，要求只回复一个新的唯一测试标记，不执行命令、不修改文件。
3. 等待对应的新一轮 `completed`，再读回同一轮并核对标记。
4. 记录实际工具名、调用时间和结果。发送结果不明时先核对目标状态，不要自动重复发送。

可使用如下测试提示词，替换为每次不同的标记：

> 这是原生控制验收。不要执行命令，不要修改文件。请只回复：WINCTRL-自定义唯一标记

## 本次端到端验收

以下时间均为 2026-11-12 北京时间（UTC+8）：

| 阶段 | 实际结果 |
| --- | --- |
| 11:17:37 | 新桌面主进程启动，确认环境含 NODE_USE_ENV_PROXY=1 |
| 11:18:46 | 云端 WebSocket 日志显示 initialized=true、next=connected、connectionError=null |
| 11:43:57.600—11:43:59.987 | Dot 原调用端原生 read_thread 成功，耗时 2.387 秒，返回同一目标聊天 |
| 11:43:58 | 本机日志对应 thread/read、thread/turns/list、thread/items/list，均 errorCode=null |
| 12:50:09.308—12:50:27.731 | Dot 向同一已有 Windows 原生聊天调用 send_message_to_thread，正常返回目标聊天 ID |
| 12:50:35 | 对应新一轮 completed，读回唯一测试标记完全一致；本地独立读取再次确认 |

Dot 侧时间和工具回执由实际调用端返回并转交核对，本机日志和原生回读另行独立验证。发送工具没有单独返回 `accepted` 或 `queued` 字段；执行成立的依据是出现了对应的新一轮，并完成和回读了预期标记。

这次验收覆盖了“实际 Dot → 已有 Windows 原生聊天 → 新一轮执行 → 完成回读”。测试未要求执行系统命令或修改业务文件，因此不扩大声称所有类型任务均已验收。

## 适用边界与撤销

- 仅在相同网络现象、版本实现及已有可用代理条件下参考此方案。插件缺失、配置目录错配、权限或其他版本问题应分别定位。
- 已通过的是原生 `read_thread` 与 `send_message_to_thread` 路径；旧 `cloud_threads.read` 路径没有单独复测。
- 重启前那次长期等待请求的远端最终结果仍未知，不能写成成功或失败。
- 这是进程启动设置，非永久修复。以后完整退出后，应继续使用脚本启动；普通入口是否继承代理开关取决于该入口环境。
- 撤销本方案：完全退出由脚本启动的应用，从未设置这些临时变量的普通入口重新启动。若此前另外手动配置过永久环境变量，应按其实际来源另行管理；脚本本身没有创建它们。
- 公开材料省略私有线程与环境 ID、设备名称、用户目录、原始日志和凭据。

## 参考讨论

- [原 issue：openai/codex #58447](https://github.com/openai/codex/issues/58447)
- [Debian 配置对齐后的恢复说明](https://github.com/openai/codex/issues/58447#issuecomment-6810062717)
- [Debian 实际调用端发送与完成回读验收](https://github.com/openai/codex/issues/58447#issuecomment-6810535406)

上述 Debian 案例通过对齐执行器配置与原生后台恢复了插件。本机未发现该错配，最终修复的是 WebSocket 环境代理。参考的是分层排查和实际调用端验收方法，不能据此断言整个 issue 的共同根因。

