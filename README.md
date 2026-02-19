# Quotio 中文增强版（中转 API 与 Token 管理中心）

本仓库是对上游 [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio) 的增强分支，目标是把 Quotio 变成一个更实用的「统一 Token 与 API 管理中心」。

仓库地址：[0xtootoo29/quotio](https://github.com/0xtootoo29/quotio)

## 你现在可以做什么

1. 在 Quotio 内直接配置 Claude Code 中转 API。
2. 将外部中转统计页面接入 Quotio，统一汇总用量。
3. 在仪表盘查看自然日 / 自然周 / 自然月的总 Token 与按模型用量。
4. 在“统计口径”里选择自动模式（外部优先，失败回退本地）。
5. 输入任意 Base URL + Token，直接查询该中转当前可调用模型列表。
6. 每日自动扫描已配置 API 的模型变化，并在 AI 代理配置下拉中可选。

## 核心能力（当前版本）

### 1. Claude Code 中转配置（MVP A）

- 支持在代理界面填写中转 URL 与 Token。
- 支持写入并更新 `~/.claude/settings.json`。
- 支持 Opus / Sonnet / Haiku 槽位配置。
- 支持日志页查看请求、模型、状态码与耗时。

### 2. 外部用量数据源聚合

在仪表盘新增「外部用量数据源」板块，可新增任意统计源并自动识别类型：

- `key-query` 类型（中转 Key 查询接口）
- `api-stats` 类型（中转统计后台接口）
- 通用 JSON 类型（自定义统计返回）

你可随时进行：新增、编辑、启用/停用、删除、手动刷新。

> Token 会存储在 macOS 钥匙串，不会明文写入普通配置。

### 3. 统计口径模式（新增）

在「外部用量数据源」板块可切换统计口径：

- `自动（推荐）`：外部优先，失败回退本地
- `仅本地`：完全忽略外部数据源
- `合并（高级）`：本地+外部，可能双计（默认隐藏，仅调试）

自动模式的外部可用判定：

- 最近抓取成功
- 返回包含有效 token 数据（day/week/month 或模型统计）
- 数据新鲜度在 10 分钟内
- 连续失败次数小于 3

### 4. 仪表盘统一 Token 统计

在仪表盘新增统一统计区块：

- 统一令牌统计（自然日 / 自然周 / 自然月）
- 各周期总 Token
- 各周期按模型聚合的 Token 与请求数

统计口径：

- 周期按本机时区自然日历计算。
- 自动模式下总量优先使用外部数据源；外部不可用时回退本地。

### 5. 模型发现与每日自动更新（新增）

在仪表盘新增「模型发现」板块：

1. 输入 Base URL
2. 输入 Token
3. 点击“查询可用模型”

程序会调用 `/v1/models` 并返回可用模型清单。

说明：

- 保留上游返回的原始模型 ID，不改名。
- 可用于快速确认中转当前开放了哪些模型。
- 支持“扫描已配置 API（每日）”，自动更新固定 API 的模型目录。
- 扫描结果会自动并入 AI 代理配置下拉，便于直接选择新模型。

## 快速开始

### 1. 环境要求

- macOS
- Xcode（完整安装）

### 2. 构建

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build
```

### 3. 启动

先定位构建产物：

```bash
find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/Quotio.app" -print
```

再启动应用：

```bash
open "/你的实际路径/Quotio.app"
```

如果 `open` 启动失败，可直接运行可执行文件：

```bash
"/你的实际路径/Quotio.app/Contents/MacOS/Quotio" >/tmp/quotio.log 2>&1 & disown
```

## 使用流程（建议）

### 步骤 1：配置 Claude 中转

在 `提供商 -> 自定义提供商` 新增你的中转：

- 名称
- Base URL
- API Key

保存后在 `代理 -> Claude Code` 配置并应用。

### 步骤 2：接入外部统计源

在仪表盘 `外部用量数据源`：

1. 点击 `+`
2. 输入名称、统计 URL、Token
3. 保存并刷新

### 步骤 3：设置统计口径

在同一板块选择：

- `自动（推荐）`

### 步骤 4：查看统一统计

在仪表盘查看：

- 日 / 周 / 月总 Token
- 各模型用量分布

### 步骤 5：查询可用模型

在仪表盘 `模型发现`：

- 输入 Base URL + Token
- 点击 `查询可用模型`
- 或点击 `扫描已配置 API（每日）` 触发一次全量扫描

## 验收命令

检查 Claude Code 配置是否写入：

```bash
grep -E "ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_DEFAULT_" ~/.claude/settings.json
```

应至少看到：

- `ANTHROPIC_BASE_URL`
- `ANTHROPIC_AUTH_TOKEN`
- `ANTHROPIC_DEFAULT_OPUS_MODEL`
- `ANTHROPIC_DEFAULT_SONNET_MODEL`
- `ANTHROPIC_DEFAULT_HAIKU_MODEL`

## 常见问题

### 1. 模型下拉没有显示新模型

- 确认中转 URL 与 Token 有效。
- 在模型发现板块先验证 `/v1/models` 返回。
- 确认代理服务在运行状态。
- 修改后重启 Quotio 再试。

### 2. 外部数据源显示“无数据”

- 检查统计 URL 是否可访问。
- 检查 Token 是否填写正确。
- 尝试手动刷新。
- 某些上游接口需要特定鉴权头，若后续接口变更需适配。

### 3. 统计数与上游不一致

- 先确认当前统计口径（自动/仅本地/合并）。
- 不同上游口径可能存在时间延迟或周期定义差异。
- 建议以外部统计源口径作为 key 总量主参考。

## 开发说明

推荐在独立分支开发：

```bash
git checkout -b codex/your-feature
```

提交后推送：

```bash
git push -u origin codex/your-feature
```

## 致谢

本项目基于上游项目开发，感谢原作者与社区贡献者：

- [nguyenphutrong/quotio](https://github.com/nguyenphutrong/quotio)

## 许可证

MIT，详见 `LICENSE`。
