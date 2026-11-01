# SWE 工作台 · SWE Workbench

**v1.1.0** · macOS 13+ · Apple Silicon

一个本地优先的 SWE 任务工作台：把个人预检、源码准备、Trae 执行、Codex 验收、
证据链和平台提交收在同一个窗口里。界面是原生 WKWebView 壳，后端是本机 Go 服务，
不需要 Electron，也不需要常驻云端。

- 仓库：<https://github.com/kekelele996/swe-workbench>
- 发布包：GitHub Releases → `SWE 工作台-1.1.0.zip`

## 功能

- **一条任务流水线**：预检 → 准备独立源码 → Trae 执行 → 补 Session/轨迹 →
  Codex 验收 → dry-run → 平台提交。
- **证据优先**：提交字段、冻结 Rubric、回执、Journal 记录链、原生轨迹、审核记录
  各自有独立视图；`unknown` 不会被显示成通过。
- **原生壳**：Swift + AppKit + WKWebView，统一标题栏、原生菜单、文件选择器、
  下载和确认对话框；退出 App 时只关闭自己启动的服务。
- **工作台设置**：GitHub 拉取代理与延迟测试、工作目录、多个 SWE 用户切换。
- **Session 核验**：完整原串对本机 Trae 日志/历史快照核验，失败时返回具体原因，
  而不是一条笼统的“未核实”。
- **本地安全边界**：服务只监听 `127.0.0.1`，写请求校验 Origin + CSRF；
  平台凭据只存在本机 `0600` 私有文件，不回显、不进入任务材料。

## 系统要求

| 用途 | 要求 |
| --- | --- |
| 运行 | macOS 13 Ventura 或更新；Apple Silicon（arm64） |
| 从源码构建 | Xcode Command Line Tools（`swiftc`）、Go 1.22+、Python 3.10+、`rsync` |
| 平台功能 | 一个可用的 SWE 平台账号；能访问 `swe.jzxhnh.com` |

> 当前只发布 arm64 构建。Intel Mac 需要自行改 `build.sh` 的 target 并重新编译依赖。

## 安装发布包

1. 从 [Releases](https://github.com/kekelele996/swe-workbench/releases) 下载
   `SWE 工作台-1.1.0.zip` 并解压。
2. 把 `SWE 工作台.app` 拖到 `/Applications`。
3. 首次打开：右键 →「打开」（App 使用 ad-hoc 签名，未做 Apple 公证）。
   如果仍被 Gatekeeper 拦住：

   ```bash
   xattr -dr com.apple.quarantine "/Applications/SWE 工作台.app"
   open "/Applications/SWE 工作台.app"
   ```

4. 首次启动按提示允许访问「文稿」目录；工作台只在所选目录内读写任务。

命令行安装：

```bash
ditto "SWE 工作台.app" "/Applications/SWE 工作台.app"
open "/Applications/SWE 工作台.app"
```

## 从源码构建

```bash
git clone git@github.com:kekelele996/swe-workbench.git
cd swe-workbench
./build.sh --no-dmg
```

`build.sh` 会按顺序完成：

1. 用 `backend/` 里的 Go 源码构建 `swe-flow` 到 `.build/swe-flow`；
2. 编译 `Sources/` 的 Swift 宿主；
3. 把 `swe-flow`、`tools/` 和 App 图标装进 App 包；
4. ad-hoc 签名，生成 `dist/SWE 工作台.app` 和
   `dist/SWE 工作台-1.1.0.zip`。

需要 DMG 时去掉 `--no-dmg`：

```bash
./build.sh
# dist/SWE 工作台-1.1.0.dmg
```

自定义后端或工具目录（例如调试一个预编译的 `swe-flow`）：

```bash
SWE_FLOW_BIN=/path/to/swe-flow ./build.sh --no-dmg
SWE_TOOLS_DIR=/path/to/tools ./build.sh --no-dmg
```

构建产物：

```text
dist/SWE 工作台.app
dist/SWE 工作台-1.1.0.zip
dist/SWE 工作台-1.1.0.dmg   # 不带 --no-dmg 时
```

安装：

```bash
ditto "dist/SWE 工作台.app" "/Applications/SWE 工作台.app"
open "/Applications/SWE 工作台.app"
```

## 首次部署与配置

### 1. 工作目录

默认顺序：

```text
--root / SWE_WORKBENCH_ROOT
→ 上次选择的目录
→ ~/Documents/ChatGPT/swe（存在时）
→ ~/Documents/SWE-work
```

菜单 **SWE 工作台 → 选择工作目录…**（⇧⌘O）可以随时切换。任务源码、工作流状态、
审核材料和轨迹都会写到这个目录下的 `sources/`、`workflow/` 等子目录。

### 2. SWE 账号

打开 **⌘, → 04 SWE 用户**，输入账号和密码，点「登录并保存」。可以保存多个账号，
在列表里切换；顶栏的 `@账号` 和总览页的「平台身份」会立即反映当前身份。

- 账号保存在 `~/.config/swe-task/config.json`（目录 `0700`、文件 `0600`）。
- 切换账号只改变平台预检/提交身份；本地任务目录是共享工作区，不会按账号复制。
- 如果启动环境设置了 `SWE_USERNAME` / `SWE_PASSWORD` / `SWE_SESSION` / `SWE_CSRF`，
  环境变量优先，设置页会提示并且不允许切换。

也可以手动准备凭据文件：

```json
{
  "schema_version": 1,
  "swe": { "username": "YOUR_ACCOUNT", "password": "YOUR_PASSWORD" }
}
```

```bash
chmod 700 ~/.config/swe-task
chmod 600 ~/.config/swe-task/config.json
```

不要把该文件提交到 Git，也不要贴到聊天或日志里。

### 3. GitHub 拉取代理（可选）

**⌘, → 01 项目拉取**：

- 默认关闭，避免 Loon 没启动时阻断 clone；
- 默认值 `http://127.0.0.1:7890`（Loon 默认端口）；
- 只作用于 `git clone` / `git fetch` 和 GitHub 语言查询，不作用于平台 API；
- 设置页的「GitHub 延迟」可以对比直连与代理，测试使用当前表单，不必先保存。

### 4. 本机服务

App 启动时会按以下顺序处理：

1. 接管上次 App 留下且校验通过的服务；
2. 若 `127.0.0.1:8765` 已有工作台，直接连接，退出时不动它；
3. 否则用 App 内置的 `swe-flow` 启动子进程；端口被占用时改用系统分配端口。

日志：`~/Library/Logs/SWE Workbench/app.log`
App 数据：`~/Library/Application Support/SWE Workbench/`

## 版本与发布

当前版本：**1.1.0**（`VERSION`，`CFBundleVersion` 2）。

版本号只有一个来源：仓库根目录的 `VERSION`。`build.sh` 读取它，写入 App 的
`CFBundleShortVersionString`，并用于 zip/dmg 文件名；`Assets/Info.plist` 和
`Sources/main.swift` 中的默认值只是兜底。

发版：

```bash
# 修改 VERSION 后
./build.sh                 # 生成 zip/dmg
git add -A && git commit -m "release: v1.1.0"
git tag -a v1.1.0 -m "SWE 工作台 1.1.0"
git push origin main --tags
gh release create v1.1.0 "dist/SWE 工作台-1.1.0.zip" \
  --title "SWE 工作台 1.1.0" \
  --notes "多 SWE 用户、设置页、Session 核验诊断与稳定性修复。"
```

### 1.1.0 主要变化

- 新增设置页：项目拉取代理、GitHub 延迟测试、工作目录、SWE 用户。
- 支持保存/切换多个 SWE 用户，顶栏常驻当前身份，切换后重置预检与平台缓存。
- Session 核验失败返回具体原因；修复历史快照工具调用匹配、会话移动和日志抖动导致的误报。
- 修复 Codex 交接开关文字竖排，以及原生编辑菜单的 ⌘C/⌘V 响应链。

## 目录结构

```text
SWE-Workbench/
├── Sources/              Swift 宿主：窗口、WKWebView、服务托管、菜单
├── Assets/               Info.plist 与图标生成脚本
├── backend/              swe-flow 的 Go 源码（自包含构建）
├── tools/                运行期 Python/Swift 工具（Trae 日志、截图等）
├── build.sh              构建 App、zip、dmg
├── VERSION               单一版本号来源
└── dist/                 构建产物（不提交）
```

`backend/` 与 `tools/` 是运行所需的完整副本；App 不依赖
`~/.codex/skills/swe-task`。设置页和 Session 核验所需的数据仍只写本机。

## 安全与隐私

- 本地服务只绑定 `127.0.0.1`，不对外监听。
- 所有非 GET 请求要求同源 `Origin` 和 `X-CSRF-Token`。
- 平台密码、Session cookie/CSRF 只写入 `0600` 私有配置；接口只返回用户名、
  姓名和角色，不返回密码或会话值。
- 任务材料、轨迹、截图默认留在工作目录；发布/分享前请自行检查是否含真实任务数据。
- App 使用 ad-hoc 签名，未公证；不要从不可信来源下载替换包。

## 故障排查

**提示“无法验证开发者”**

右键 →「打开」，或执行上面的 `xattr -dr com.apple.quarantine`。这是未公证 App 的
正常提示，不代表构建失败。

**窗口停在“本地服务没有启动”**

打开 `~/Library/Logs/SWE Workbench/app.log`，检查端口、工作目录、内置
`Resources/bin/swe-flow` 是否存在。命令行复现：

```bash
"/Applications/SWE 工作台.app/Contents/Resources/bin/swe-flow" \
  serve -root "$HOME/Documents/SWE-work" -port 8765
```

**截图/轨迹功能报权限错误**

到「系统设置 → 隐私与安全性 → 屏幕录制」勾选「SWE 工作台」，然后重启 App。

**Session 核验失败**

现在页面会显示具体原因。常见情况：

- `原串会话与指定工作区不一致`：复制到了另一个 Trae 会话；
- `历史快照与 Session 原串时间不一致`：原串与完成轮次不对应；
- `核验期间日志发生变化`：Trae 还在写，等两秒重试；
- `日志有效轮数与提交材料不一致`：日志轮数与预期不一致。

**升级后数据还在吗**

在。升级只替换 `/Applications` 下的 App；`~/Library` 配置、工作目录和任务材料不动。

## 已知限制

- 仅提供 arm64 构建；Intel Mac 需自行调整 target。
- 未做 Apple 公证，首次启动需右键打开。
- 没有自动更新器；升级方式为下载新 zip 覆盖 App。
- 工作台是本地任务工具，不是多租户服务器；不要把它暴露到公网。
