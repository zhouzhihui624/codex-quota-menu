# Codex Quota Menu

一个轻量的原生 macOS 菜单栏工具，以五格样式实时显示 Codex 的 5 小时和 7 天剩余额度。

真实菜单栏截图：

![Codex 实时额度菜单栏截图](screenshot.png)

## 功能

- 同时有 `5h` 和 `7d` 时使用紧凑双行；只有一个额度窗口时自动切换成更大的单行显示。
- 五格进度条：绿色 ≥ 50%，橙色 20%–49%，红色 < 20%。
- 每 60 秒自动刷新，也可从菜单中手动刷新。
- 自动绑定 Codex 桌面端：Codex 启动时显示，退出时移除菜单栏项目。
- 点击菜单栏项目可查看重置时间，并打开 Codex 用量页面。
- 原生 Swift + AppKit，无第三方运行时依赖。

## 行为

- 检测 Bundle ID `com.openai.codex`（当前桌面应用可能显示为 `ChatGPT.app`）。
- Codex 启动后显示菜单栏额度；Codex 退出后移除菜单栏项目。
- 每 60 秒从本机 `~/.codex/auth.json` 读取当前登录态，并向 Codex 用量接口刷新一次。
- 兼容新旧额度响应：不再固定把 `primary` 当作 5 小时、`secondary` 当作 7 天，而是根据窗口时长识别。
- 如果 HTTP 响应缺少窗口，会通过本机 Codex `app-server` 的 `account/rateLimits/read` 补充；服务端确实未提供的窗口显示 `--%`，避免展示错误额度。
- 百分比和格数均表示剩余额度：绿色 ≥ 50%，橙色 20%–49%，红色 < 20%。
- Token 只用于访问 OpenAI 的 Codex 用量接口，不写入日志、不上传到其他服务。
- 后台监听器由用户级 LaunchAgent 启动；Codex 未运行时不显示图标，也不请求网络。

## 安装

```bash
git clone https://github.com/Flier123/codex-quota-menu.git
cd codex-quota-menu
./install.sh
```

安装脚本会：

1. 使用系统 Swift 编译器构建并临时签名应用。
2. 安装到 `~/Applications/Codex 实时额度.app`。
3. 注册用户级 LaunchAgent，用于监听 Codex 启动与退出。

如果没有 Swift 编译器，请先运行 `xcode-select --install` 安装 Apple Command Line Tools。

### macOS 26 菜单栏兼容模式

如果系统设置中已允许 `Codex 实时额度` 显示在菜单栏，但原生状态项仍不可见，可以启用兼容浮层：

```bash
defaults write local.codex.quota-menu UseOverlayMenuBar -bool true
launchctl kickstart -k "gui/$(id -u)/local.codex.quota-menu"
```

兼容浮层只在系统菜单栏可见或从全屏中展开时出现，并保留点击查看详情、手动刷新和打开用量页面的功能。默认位置不合适时，可以调整距屏幕右侧的距离（单位为点）：

```bash
defaults write local.codex.quota-menu OverlayRightInset -float 586
launchctl kickstart -k "gui/$(id -u)/local.codex.quota-menu"
```

恢复原生状态项：

```bash
defaults delete local.codex.quota-menu UseOverlayMenuBar
launchctl kickstart -k "gui/$(id -u)/local.codex.quota-menu"
```

## 卸载

```bash
./uninstall.sh
```

## 手动构建

```bash
./build.sh
```

要求 macOS 14 或更高版本，以及系统自带的 Swift 编译器。

## 隐私与说明

- 本工具只读取本机 Codex 登录文件中的访问令牌，并只向 `chatgpt.com` 的 Codex 用量接口发送请求；兼容回退仅调用本机 Codex 自带的 `app-server`。
- 不包含遥测、分析或第三方服务器。
- 当前额度接口属于 Codex 客户端使用的内部接口，OpenAI 更新接口后可能需要同步适配。
- 本项目是社区开源工具，与 OpenAI 无隶属或背书关系。

## License

[MIT](LICENSE)
