# ZCode 遥控（HarmonyOS）

用鸿蒙手机扫码连接电脑端 **ZCode** 的远程控制面板，查看任务工作状态并下指令。
实现方式是 **ArkWeb WebView 套壳**：加载 `https://zcode.z.ai/remote/...`，效果与浏览器打开一致。

- 仓库：https://github.com/jvkdhb/zcode-remote
- 下载：https://github.com/jvkdhb/zcode-remote/releases （未签名 HAP，需侧载工具）

## 功能

- **扫码连接**：系统扫码 UI（`@kit.ScanKit`），无需相机权限；也可粘贴链接
- **App 内登录**：ArkWeb 多窗口承载授权页，cookie 与主 WebView 共享
- **最近连接**：本地保存最近 5 条（Preferences，不写日志）
- **任务查看与指令**：任务列表 / 任务会话 / 输入框，与网页端一致
- **产出物下载**：点附件/产出物的下载按钮 → 系统「另存为」面板选位置直接保存
- **强制深色**：整套深蓝配色，强制深色主题（不支持浅色）
- **界面精简**：顶部单行工具栏、输入栏贴底、SPA 路由切换后自动恢复样式
- **跳转浏览器**：工具栏「浏览器」可用系统浏览器打开当前会话

## 下载与安装

1. 从 [Releases](https://github.com/jvkdhb/zcode-remote/releases) 下载最新版 `ZcodeRemote-v18-unsigned.hap`
2. **未签名包**，需要 **HoKit** 等侧载工具安装（系统设置/应用市场无法安装）
3. 要求：HarmonyOS NEXT（API 24+，实测 API 26）

## 使用

1. 电脑端 ZCode 打开「远程控制」面板，得到二维码/链接
2. 手机 App 扫码或粘贴链接
3. 登录弹窗选 **「中国」**，使用与电脑端相同的智谱（BigModel）账号

## 构建

需要 DevEco Studio（含 SDK、Node、hvigor、ohpm）。

```cmd
set "PATH=<DevEco>\tools\node;<path-to-devecocli>;%PATH%"
cd /d <project-dir>
devecocli build
```

产物：`entry\build\default\outputs\default\entry-default-signed.hap`

签名需使用**你自己的**华为账号调试证书（IDE 自动签名或 `devecocli signature generate`），仓库不包含任何签名材料。

## 技术要点

- 远程页是 Tailwind + CSS 变量的 SPA，主题/布局修正在 `javaScriptOnDocumentStart` 注入并常驻自愈（MutationObserver + 防抖），路由切换不会被重置
- 下载接管：`WebDownloadDelegate.onBeforeDownload` → 系统另存为（`DocumentViewPicker.save`）→ `WebDownloadItem.start`
- 登录留存在 App 内：`multiWindowAccess` + `onWindowNew` 把授权页留在应用内

## 已知限制

- 不支持浅色主题（已强制深色）
- 登录态保存在 App 内，卸载重装需重新登录

## 许可

MIT