# Quotio 中文增强版（Claude 中转专用分支）

本仓库是对上游 [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio) 的个人分支，目标是让 Quotio 更适合 Claude Code 中转 API 场景，并保持配置流程简单、可验证、可迭代。

仓库地址：[0xtootoo29/quotio](https://github.com/0xtootoo29/quotio)

## 项目目标

1. 让 Quotio 能稳定识别并写入 Claude Code 中转配置
2. 支持多中转供应商接入与可视化使用情况
3. 在仪表盘提供更细粒度的令牌统计（自然日 / 自然周 / 自然月）

## 已完成功能

### 1. Claude Code 中转配置（MVP A 已完成）

- 支持在 Claude 配置界面直接填写中转基础地址与密钥
- 支持读取既有配置并回填到 UI
- 自动处理 `/v1` 路径规范化
- 可将配置写入 `~/.claude/settings.json`
- 代理请求可在 Quotio 日志页查看

### 2. 自定义供应商与模型可见性优化

- 支持接入多个 Claude 兼容中转
- 在代理模型下拉中展示更直观的模型文案（含别名与目标模型信息）
- 兼容不同中转返回的模型列表格式

### 3. 配额页中转额度同步（已接入）

- 支持将中转额度接口数据同步到 Quotio 配额页面
- 可在 Claude Code 分组中查看对应供应商额度

### 4. 仪表盘令牌统计增强（本次更新）

- 新增自然日、自然周、自然月总令牌统计
- 新增各时间周期下按模型聚合的令牌用量
- 统计按本地时区自然周期计算
- 后台历史保留策略已增强，避免月度统计因历史裁剪而失真

## 快速开始

### 1. 环境要求

- macOS
- Xcode（完整安装，不仅是命令行工具）

### 2. 构建应用

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build
```

### 3. 启动应用

先定位构建产物：

```bash
find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/Quotio.app" -print
```

再启动：

```bash
open "/你的实际路径/Quotio.app"
```

若 `open` 失败，也可以直接启动可执行文件：

```bash
"/你的实际路径/Quotio.app/Contents/MacOS/Quotio" >/tmp/quotio.log 2>&1 & disown
```

## 配置步骤（Claude 中转）

### 1. 添加中转供应商

在 `提供商` -> `自定义提供商` 中新增：

- 名称：自定义（例如 `ccmix`）
- 中转地址：你的中转地址
- 密钥：你的中转密钥

保存并确保供应商状态可用。

### 2. 配置 Claude Code 代理

在 `代理` -> `Claude Code` 中：

- 连接模式：`Proxy`
- 配置模式：`Automatic`
- 存储方式：`JSON`（或 `Both`）
- 填写代理 URL 与 API 密钥
- 选择 Opus / Sonnet / Haiku 槽位模型
- 先点“测试连接”，再点“应用”

### 3. 命令行验收

```bash
grep -E "ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_DEFAULT_" ~/.claude/settings.json
```

应至少出现：

- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`

随后在 Claude Code 中发起一次真实请求，在 Quotio 的 `日志` 页面确认请求记录与模型信息。

## 仪表盘令牌统计说明（新增）

统计来源：Quotio 代理层记录的每次请求响应令牌信息。  
统计范围：当前本地请求历史（已提升保留上限，用于支持月度观察）。  
周期定义：

- 日：本地时区自然日（00:00 - 24:00）
- 周：本地时区自然周（系统日历 `weekOfYear`）
- 月：本地时区自然月

展示内容：

- 每个周期总令牌
- 每个周期内按模型聚合的令牌与请求次数

## 常见问题

### 1. 模型下拉看不到预期模型

- 确认 Quotio 代理正在运行
- 确认自定义供应商已启用
- 在代理配置窗口中刷新模型
- 修改供应商后重启一次 Quotio

### 2. `~/.claude/settings.json` 没有更新

- 确认模式为 `Proxy + Automatic`
- 确认点击了“应用”（不仅是“测试连接”）
- 检查目标文件权限

### 3. 终端没有 `rg`

本仓库文档中的过滤命令都可用 `grep -E` 替代，例如：

```bash
grep -E "ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_DEFAULT_" ~/.claude/settings.json
```

### 4. `open ...` 报错（如 -609）

- 先确认 `Quotio.app` 路径是否正确
- 使用绝对路径执行 `open -na "/实际路径/Quotio.app"`
- 或直接执行 `Contents/MacOS/Quotio` 启动

## 后续规划

下一阶段为模型分流（MVP B）：

- `Opus` 走指定高能力中转
- `Sonnet / Haiku` 走其他供应商
- 支持可视化路由策略与更细粒度回退策略

## 致谢

本项目基于上游项目开发，感谢原作者与社区贡献者：

- [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio)

## 许可证

MIT，详见 `LICENSE`。
