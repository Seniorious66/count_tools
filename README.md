# count_tools

这是 [fmqwd/count_tools](https://github.com/fmqwd/count_tools) 的个人客制化 fork，采用 Apache-2.0。
开发先读 [指导文档](docs/DEVELOPMENT_GUIDE.md)、[项目约定](AGENTS.md) 和 [设备流程](docs/MOBILE.md)。
规划唯一来源：`outputs/workflow-20261011/CountTools-MasterSheet.xlsx`。

当前完成流程基线，未发布个人 APK。固定基线 `baseline/upstream`，开发分支 `personal/customization`；不自动同步上游。
个人身份、签名、Flutter工具链待首个产品版确定。真数据/签名不入Git；CI仅手动规划检查。
暂定业务需求：[Cheki V0.2 原文](docs/requirements/CHEKI_V0.2.md)；[评估与初步设计](docs/requirements/CHEKI_DESIGN_V0.2.md)。
WF-002 已纳入四表规划，功能尚未实施；后续按相依决定和版本路线推进。
WF-003 已区分工作包、产品版本和 M0–M5 里程碑，用户选择核心 MVP 先行；[升版原则与阶段检查](docs/PLANNING_AND_ACCEPTANCE.md)。各业务阶段尚未开始。
WF-004 已核验 E/NAS 双备份，后续每次提交自动推送个人 fork 并核对远端；首次克隆先按 [提交追溯指导](docs/GIT_TRACEABILITY.md) 启用仓库 hooks。真实备份和签名始终在 Git 外。

```powershell
python scripts/verify-mastersheet.py
.\scripts\use-dev-env.ps1 -Inspect
```

以下保留上游初始项目说明。

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Lab: Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Cookbook: Useful Flutter samples](https://docs.flutter.dev/cookbook)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
