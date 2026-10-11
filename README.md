# count_tools

基于「统计工具」的个人客制化项目，计划面向中国本土地下偶像爱好者，提供 **Cheki（拍立得合影）记录与特典券管理**。

希望解决的日常问题是：拍过多少张、哪些还没完成或领取、手里有哪些券，以及每次拍切实际用了什么券。多人合影的实物张数与成员参与数分开统计，券库存与历史成本可以追溯。

## 当前状态

项目处于**需求设计与开发准备阶段**。目前已整理需求、初步设计、MVP 路线和阶段验收方法，并建立开发与提交追溯流程。

仓库现有业务代码仍是上游的通用统计工具，采用 Flutter / Dart / SQLite。下述 Cheki 与特典券功能**尚未实现**，目前也没有可供安装的个人版 APK。工具链、个人应用身份与签名仍需在工程基础阶段确定。

## 核心 MVP：计划先交付什么

先完成从记录到库存、纠错和恢复的日常使用闭环：

- **团体与成员**：管理成员身份及历史名称，保留跨团和改名后的记录关联。
- **Cheki 记录**：单人及多人合影，记录尺寸、签名、背签与宿题；分别管理完成和领取状态，支持一批记录部分完成或领取。
- **特典券库存**：购券、长期券与限时券、期限和成本记录；拍切时明确选择实际使用的券。
- **可靠登记与纠错**：记录和扣券共同成功或失败，重复提交不重复扣券；支持交换、赠送、编辑、撤销及关联纠错。
- **基本统计与数据保护**：查看实际张数、参与数和库存；完整备份并恢复 MVP 当时的业务数据与设置。

完整 BI、结构化批量导入导出及原 App 历史数据迁移安排在 MVP 之后。旧数据先保留原始记录，经过映射预览和核对后再迁移。

## 交付路线与检查点

| 阶段 | 计划交付 | 检查重点 |
| --- | --- | --- |
| M0 | 工程与数据安全基础 | 可重复构建，隔离备份恢复，失败时原库不变 |
| M1 | 记切预览 | 单人/多人数量、尺寸与状态口径正确 |
| M2 | 核心 MVP | 购券、登记扣券、状态、交换/赠送、纠错与恢复的完整闭环 |
| M3 | 完整 BI | 同一筛选下，统计、明细、图表和导出结果一致 |
| M4 | 批量数据携带与旧历史迁移 | 导入预检、重复处理、映射预览与往返校验 |
| M5 | 日用验收 | 实际升级、数据核对、交互、冷启动和恢复 |

以上均为计划阶段，尚未开始业务实施。具体工作包、依赖、估算、决定和实际进度统一维护在 [MasterSheet](outputs/workflow-20261011/CountTools-MasterSheet.xlsx)。大小版本的触发条件、MVP 边界和各阶段检查示例见 [版本规划与阶段验收指导](docs/PLANNING_AND_ACCEPTANCE.md)。

## 需求与开发文档

- [需求原文 V0.2](docs/requirements/CHEKI_V0.2.md)：暂定业务与功能需求。
- [评估与初步设计](docs/requirements/CHEKI_DESIGN_V0.2.md)：现有差距、页面构思、数据模型和待裁决问题。
- [UI 设计规范与原型](docs/UI_DESIGN.md)：参考 SalaryFlow 极简布局，采用浅蓝与浅粉拼色；可点击预览主要页面和登记流程。
- [开发指导](docs/DEVELOPMENT_GUIDE.md)：环境、实施、验证与交付方法。
- [项目开发约定](AGENTS.md)：每轮规划、数据保护和验收规则。
- [Git 提交追溯](docs/GIT_TRACEABILITY.md)：本地提交、自动上传和失败重试。
- [设备流程](docs/MOBILE.md)：安装身份检查、备份、升级和真机验收。

## 本地开发

个人开发分支为 `personal/customization`，`baseline/upstream` 保留上游基线。默认不自动合入上游变更。

```powershell
git clone --branch personal/customization https://github.com/Seniorious66/count_tools.git
cd count_tools
git config --local core.hooksPath .githooks
python scripts/verify-mastersheet.py --baseline HEAD
```

开始业务开发前，按 [开发指导](docs/DEVELOPMENT_GUIDE.md) 建立并验证工具链。仓库提交 hooks 的配置要求见 [Git 提交追溯](docs/GIT_TRACEABILITY.md)。真实数据库、系统备份和签名保存在仓库之外；开发验证使用合成数据或隔离副本。

## 来源与许可证

本项目 fork 自 [fmqwd/count_tools](https://github.com/fmqwd/count_tools)，感谢原作者的统计工具实现。

沿用 [Apache License 2.0](LICENSE)。保留原作者署名与第三方许可，客制化开发独立推进。
