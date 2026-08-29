# SCV Control

[English](README.md)

SCV Control 是一个面向 Factorio 2.0 的实验性 Mod，用 RTS 风格的鼠标指令替代角色的直接移动。

## 当前功能

- 右键点击空地：替换当前指令并移动到目标位置。
- `Shift + 右键` 点击空地：把移动指令追加到队列。
- 按“向下移动”对应按键（默认 `S`）：停止移动并清空队列。
- Mod 会接管原版方向移动控制。
- 鼠标位于 GUI 或实体上、手持物品时，右键操作会交还给原版游戏。
- 寻路使用当前角色的碰撞箱和碰撞层。
- 每位玩家拥有独立且可配置的指令队列。

这是一个早期原型。请先在测试存档中使用。

## 已知限制

- 已在 Factorio 2.0.77 本地验证 Mod 加载和生命周期；交互移动仍需要更完整的实际游玩测试。
- 当前版本接管方向键，因此暂不支持驾驶载具。
- 目前只支持空地移动，采矿、维修、攻击和进入载具等情境指令尚未实现。

## 安装

开发时，把本目录放入或链接到 Factorio 的 `mods` 目录。发布时，将目录打包为 `factorio-scv-control_0.1.0.zip`。

## 本地测试

在 PowerShell 7 中运行纯无头 agent 测试：

```powershell
pwsh -File .\tools\test.ps1
```

默认命令会在隔离临时目录运行 smoke 与真实引擎 integration 套件，验证加载、120 tick 生命周期、路径优化、移动跟随、队列顺序、光标到指令的转换和不可达目标。失败时会自动保留诊断产物。详见 [docs/testing.md](docs/testing.md)。

创建或刷新交互测试存档：

```powershell
pwsh -File .\tools\create-test-save.ps1 -Force
```

该脚本会在正常 Factorio Mod 目录中建立开发链接、启用 Mod，并在正常存档目录创建 `SCV Control Test.zip`。存档包含直线移动、绕障寻路、窄通道、队列路径点、不可达目标和未来情境指令等测试区。存档内可使用 `/scv-test-home` 或 `/scv-test-reset`。

测试场会自动把每次移动点击、寻路请求、寻路结果、完整路径点、路径长度、绕行比例和重算原因写入 `%APPDATA%\Factorio\script-output\scv-control\planner.jsonl`。使用 `/scv-test-clear-log` 可以开始一次干净的记录。

## 路线图

- 改进动态障碍附近的路径跟随和脱困逻辑。
- 增加持续显示且带编号的队列标记。
- 增加采矿、维修、攻击和进入载具等情境指令。
- 增加 RTS/直接控制模式切换。
- 增加原创 SCV 风格角色原型和视觉资源。
- 增加自动打包和更完整的本地集成测试。

## 许可

[MIT](LICENSE)
