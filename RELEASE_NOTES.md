# v1.0.0-fixed 发布说明

## 这是什么

**Claude Desktop 中文补丁 · 修复版**。基于 [javaht/claude-desktop-zh-cn](https://github.com/javaht/claude-desktop-zh-cn) 修复,解决原版在当前 Claude 版本 + 3P 模式下的白屏和兼容性问题。

## 怎么用(Windows)

1. 下载本仓库源码(右上角 Code → Download ZIP)。
2. 解压。
3. 双击 `Claude简体中文管理器.cmd`。
4. 按提示选择"一键汉化"。

卸载时再运行一次管理器,选"卸载汉化"即可。

## 本版修复了什么

- 修复 3P 模式白屏(原版批量改 JS 导致 `SyntaxError`)
- 补全新版 Claude 的 `LOCALAPPDATA` 配置路径
- 重写安全备份机制,按版本备份,拒绝旧版本覆盖新版本
- 解决文件权限问题
- 新增一键管理器(汉化 / 修复 / 卸载 / 查看日志)

## 注意

- 仅 **Windows** 测试通过;**macOS 未测试**,请谨慎使用。
- 不修改 `Claude.exe`、`app.asar`,不改 API 密钥、Gateway 和 3P 模型配置。
