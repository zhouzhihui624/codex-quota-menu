# Codex Quota Menu

一个轻量的原生 macOS 菜单栏工具，按两行五格样式实时显示 Codex 的 5 小时和 7 天剩余额度。

![Codex 实时额度菜单栏示意图](preview.png)

## 功能

- 两行紧凑显示 `5h` 和 `7d` 剩余百分比。
- 五格进度条：绿色 ≥ 50%，橙色 20%–49%，红色 < 20%。
- 每 60 秒自动刷新，也可从菜单中手动刷新。
- 自动绑定 Codex 桌面端：Codex 启动时显示，退出时移除菜单栏项目。
- 点击菜单栏项目可查看重置时间，并打开 Codex 用量页面。
- 原生 Swift + AppKit，无第三方运行时依赖。

## 行为

- 检测 Bundle ID `com.openai.codex`（当前桌面应用可能显示为 `ChatGPT.app`）。
- Codex 启动后显示菜单栏额度；Codex 退出后移除菜单栏项目。
- 每 60 秒从本机 `~/.codex/auth.json` 读取当前登录态，并向 Codex 用量接口刷新一次。
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

- 本工具只读取本机 Codex 登录文件中的访问令牌，并只向 `chatgpt.com` 的 Codex 用量接口发送请求。
- 不包含遥测、分析或第三方服务器。
- 当前额度接口属于 Codex 客户端使用的内部接口，OpenAI 更新接口后可能需要同步适配。
- 本项目是社区开源工具，与 OpenAI 无隶属或背书关系。

## License

[MIT](LICENSE)
