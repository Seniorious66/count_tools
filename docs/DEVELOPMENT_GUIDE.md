# 统计工具后续开发指导

2026-10-12 新增 DEC-045：[信息可空与补录要求](requirements/INCOMPLETE_ENTRIES_20261012.md)。所有业务条目信息可以为空；已知旧信息先保存，以后在 App 编辑补齐，不以新建默认值猜测历史。技术 ID/动作戳/修订仍生成；正式或合适版本前另复核，不能随升版自动恢复必填。此规则优先于本文件和旧 UI 规范中的完整性限制。

当前 v1.2.1 已接实际可空保存/编辑服务、首页月份/未领/最近记录、日期分组和成员/尺寸/日期筛选、详情与修改对照；主导航首页/记录，旧版项目仍可从管理访问。schema 5 不变，汇总只读派生，按指标所需的已知字段计算，缺失单列；补齐只替换改动字段，保持缺键/NULL/空列表/原文/ID/ext/创建时间，留新修订。完整多次补领、记录名称快照和 M1 综合候选材料尚未齐备，工作包保持进行中；本地页面检查不替代 M1 验收。M2 券事务只在其必要条件可验证时执行，M4 批量原档映射仍先预览，不把可空规则当真实导入授权。

## 起点与参考

2026-10-11 建立 WF-001 流程；没有改业务、身份、签名或数据库，没有构建/安装个人 APK。
上游 https://github.com/fmqwd/count_tools ，fork https://github.com/Seniorious66/count_tools 。
固定 `baseline/upstream`，开发 `personal/customization`；WF-001 建立时尚未提交，后续提交上传按 Git 追溯记录核对，Apache-2.0 保留。

参考 `E:\OneDrive\Code\财务\salaryflow` 的 AGENTS、README、MOBILE、环境/构建/测试脚本及当前四表。
本轮没有修改参考项目；不继承工资公式、S25/OEM规则、十个工作日观察期或旧许可证限制。

| SalaryFlow 机制 | 本仓库适配 |
| --- | --- |
| 四表 MasterSheet 唯一来源 | outputs/workflow-20261011/CountTools-MasterSheet.xlsx |
| 每轮先计划再补同一日志 | AGENTS + 唯一 ROUND ID + 历史保留检查 |
| 高耦合基础优先 | 身份/环境 → 备份恢复 → schema迁移 → 确认后的功能 |
| 独立上游与开发分支 | baseline/upstream、personal/customization，不自动同步 |
| React/Core/typecheck/build | Flutter analyze/test/build，不复制 npm/Capacitor |
| 固定签名与递增版本 | 首次身份决定后建立专属外部证书和正式构建脚本 |
| 本地/设备验收分开 | 明确设备授权，候选按versionCode，累计未验风险 |
| 隔离测试保护真数据 | 仓库外只读原备份，隔离写测试与回滚 |
| 精简证据与规划校验 | verify-mastersheet.py、verify-database.py、文本结论 |

## 当前缺口

以下为 WF-001 建立时的历史缺口。2026-10-11 用户已批准独立包名 `com.seniorious66.counttools`、显示名「Cheki账本」、专属永久签名及 E/NAS 双备份，并确认固定 Flutter 3.47.5 的兼容升级路线。M0 实施状态与实际验证结果以 MasterSheet 为准，不能从脚本存在推断构建已通过。

- 原安装是 com.example.count_tools / 1.0.0 / 1；设置页观察到1.0.4，源码 AppInfo 为1.0.2。源码与APK尚未证明精确对应。
- 本机 PATH 没有 Flutter/Dart。源码要求 Dart >=2.19.2 <3.0.0；Gradle7.5、AGP7.2.0、Kotlin1.7.10。不能直接套 SalaryFlow JDK21。
- Android 未跟踪 gradlew；旧 CI 从根目录调用 gradlew。已改为手动规划检查，未冒充有效 Flutter 构建。
- 默认计数器模板测试不能代表业务。首次开发需替换为与 App 行为相符的隔离测试，不能跳过失败。
- pubspec.lock 原被忽略；本轮解除忽略，首次SDK固定后解析、检查、提交锁文件，不自动全量升级依赖。
- 源码 release 使用debug signingConfig，并含上游更新地址；原安装私钥未知。下一开发版处理，当前未改产品。

## 文件职责与规划表

AGENTS.md 是后续规则；MasterSheet 是范围/状态/依赖/风险/决定/每轮历史的唯一可编辑来源；
本文是操作指南，MOBILE.md 是身份与数据验收；docs/personal/WF001_DELIVERY.md 是本轮事实。

四表与 SalaryFlow 同名：版本规划、Changelog、决策与风险、执行约定。
工作包含目标、收益、状态、优先级、硬依赖、估算、范围、验收、门槛、影响和候选code下界；O/P/Q 列分别列 App 产品目标、所属里程碑和拆分/升版理由。
原 v-ID 是历史工作包编号，不直接用作 App versionName；多个工作包可组成一个产品版。WF-013 起，同一“版本规划”按 M0–M5 开发段排列，各段工作包后紧接本段 M 检查点和专用表头；UI-FIX-001 在 M1 前置区，其他流程设计放在追溯区。按工作包/M ID 定位，不绑定行号；工作包和检查点各用紧邻表头读列。
大小版本触发、耦合拆包、已选核心 MVP 和用户检查方法见 [版本与阶段验收指导](PLANNING_AND_ACCEPTANCE.md)。
“待开发”是排期，不是已批准实施；估算空白表示未估算，0只用于无开发工作量基线。
每轮 Changelog 同一 ID 起草后补结果，结束历史不覆盖；纠错追加来源和原因。
DEC/RISK ID 保留；描述修正另记，状态与新证据可追加。重新排范围要先保留被替换范围和理由。

## 每轮操作

1. 读工作区/分支和四表，选一个依赖适用工作包，核对所属产品目标/里程碑，不覆盖用户改动。
2. 向用户输出“本轮规划”：工作包、产品目标/阶段、目标/范围、文件、不做项、验收、未决决定。
3. Changelog新建ROUND后实施；变化同步版本/风险/依赖/估算，不静默扩范围。
4. 在本地和隔离数据上验证；未决只阻塞相依工作，不停止其他授权工作。
5. 跑检查，逐项记录通过/失败/未执行；修本轮引入问题，保留既有失败。
6. 有APK交付时正式签名、包名/证书/递增版本及最终内容校验，输出local-artifacts/android。
7. 无设备授权停在本地交付，登记候选与风险；获准才按MOBILE验收。
8. 补同一ROUND、更新版本状态与历史校验，交付实际结果和下一步。

WF-004 用户已持续授权每次提交推送个人 fork。每轮使用 [提交追溯指导](GIT_TRACEABILITY.md) 的入口：提交前检查暂存内容与历史，提交后自动推送 `origin` 个人分支并查询远端。失败保留提交、报告“未上传”，重试后再称上传完成；不 force、不同步上游，不附带发布制品。

阶段交付时提供可操作隔离候选、步骤/预期、实际前后对账与恢复证据、未验问题；用户复核后补阶段结论。工作包、本地验证、候选、实机和阶段验收分别记，不用完成百分比替代门槛。

## 检查命令

Python检查仅用标准库，不依赖安装Flutter：

```powershell
python scripts/verify-mastersheet.py
python scripts/test-workflow.py
python scripts/test-git-trace.py
# 首个含工作簿的提交建立后每轮必跑：
python scripts/verify-mastersheet.py --baseline HEAD
python scripts/verify-database.py --database 'E:\OneDrive\Code\artifacts\count-tools-export\20261011_102725\user_database.db'
.\scripts\use-dev-env.ps1 -Inspect
```

首次工具链固定后，给当前终端显式配置仓库外SDK：

```powershell
. .\scripts\use-dev-env.ps1 -FlutterRoot 'C:\独立工具目录\flutter' -JdkRoot 'C:\独立工具目录\jdk' -AndroidSdk 'C:\Users\Aphoe\AppData\Local\Android\Sdk'
.\scripts\test-local.ps1 -Baseline HEAD
# 可选本地调试编译，不连接/安装手机：
.\scripts\test-local.ps1 -Baseline HEAD -BuildDebug
```

环境入口不会下载SDK或连接设备；本地入口依次规划、流程保护回归、依赖解析、analyze、test，失败即停。
Debug APK 不是正式交付，不能替换真实安装。没有有效产品测试就不能标记本地完成。
M0 已建立 `build-personal-android.ps1`：显式候选名称/code、仓库外签名配置、独立 Android 工作目录、锁文件解析、实际签名和包名/版本核验，成功后写本地候选台账并要求以后 code 递增。构建不安装、不发布；实际通过状态看 MasterSheet。
改MasterSheet使用支持原格式的工作簿工具；只读校验器不会改表。首次工作簿未入Git时仅报告历史基线尚未建立，不能声称 --baseline HEAD 通过。
WF-002 起，“执行约定”维护 REQ 需求覆盖行：来源章节、目标版本、验收与状态。校验器检查关联版本/完整性；历史需求 ID 不可删除，改范围或验收须归档原六列完整 JSON 行，状态可以据证据推进。
WF-003 起，校验器同时检查 M 阶段覆盖、产品目标映射、阶段硬依赖和完成门槛；修改已有产品/阶段范围同样归档原完整行。校验通过只证明规划记录一致，不证明业务已实现。
WF-013 起，LAYOUT-001 约定各 M 检查点紧接所属最后一个工作包（中间仅检查表头）；校验器检查阶段位置和 UI-FIX-001 前置位置。流程回归按稳定 ID 修改测试数据，避免表格重排使原负例失效。

## 下一开发版

2026-10-12 当前用户目标为推进到 M1 达成前：完整实施 v1.2.0 与 v1.2.1 的本地功能、隔离验证和候选，交检查材料后停在 M1 阶段复核前，不进入 M2、不连接手机或写真实数据。用户 AGENTS 已明确 Flutter / Dart / SQLite 路线；同日已确认 DEC-008/014 的历史名、转团新身份、手动同人关联及单张最多同人一个身份，也确认 DEC-019 产品版本序列。不能按同名自动关联。

2026-10-11 的历史范围为 M0 三个工作包，完成 M0 后停止；当时未授权 M1。下文原建议保留为阶段设计背景，身份和 SDK 裁决已完成。

WF-001 当时建议先推进工作包 v1.1.0 / 候选code下界11000：身份、可重复工具链、有效测试基线、上游更新链解耦，归属 M0 工程候选。当时未改产品版本元数据；本轮已设置个人工程候选元数据，实际构建与验证状态见 MasterSheet。
推荐独立包名如 com.seniorious66.counttools 并保留原App；显示名/身份由用户确认。
要原位替换原App必须先取得并验证同签名私钥，源码/调试授权不够；禁止卸载解决签名冲突，不借用SalaryFlow证书。
独立个人版首装不会自动拥有旧库。v1.1.1建立全量备份/导入预检/预览/原子替换/回滚，隔离往返通过后才能授权迁移真数据。M0 的电脑工程入口和操作步骤见 [恢复指导](RECOVERY.md)，App 内用户页面在 M2 按 UI-05 实施；工程工具通过不代表手机已恢复。
v1.1.2建立稳定schema与逐级迁移。2026-10-11 WF-002 已将暂定 Cheki V0.2 评估和初步设计纳入 MasterSheet，业务仍未实施。
需求原文见 [CHEKI_V0.2.md](requirements/CHEKI_V0.2.md)，评估/页面/模型/未决规则见 [CHEKI_DESIGN_V0.2.md](requirements/CHEKI_DESIGN_V0.2.md)。
v1.2.0 起按四表工作包推进团体/身份、Cheki、券库存/联动、成本纠错、BI、批量携带和旧映射；用户已选择 M2 核心 MVP 先行，完整 BI 与批量旧迁移后交。每个新增持久化包扩展当前模型备份，M2 的全模型恢复是试用门槛；本文不另维护排期。
实施相依版本前裁决四表 DEC 的时间、未知成本、交换 FIFO、下游纠错与多人 BI 门槛；暂定需求与建议路线不等于全路线实施授权。

## SQLite耦合和验收

当前业务修订先读 [最新日期与登记规则](requirements/CHEKI_ENTRY_20261011.md) 和 [时间、领取与编辑基础](requirements/CHEKI_CHANGE_20261011.md)：发生信息只到天，操作时间戳另存；成员下拉；无签/有签/宿题互斥，背签依赖有签；三领取选择默认已领取，新建默认扣券，登记两页。初始已领取采用不设实际领取时间的允许方案，不能把无时间已领误判未领。旧完成原始事实、旧时间点和缺失领取时间保留追溯。

界面设计与实现先读 [UI 规范](UI_DESIGN.md) 和其中的可点击原型。用户已指定 SalaryFlow 极简风及浅蓝浅粉拼色；布局待复核，四表仍维护范围和进度。按规范建立公共主题和组件，颜色不能替代状态文字，成员自定义颜色保留。HTML 原型的浏览器检查与 Flutter 构建、真实 Android 大字/键盘/读屏验收分别记录。

当前 v1.2.0 源码使用公共 R1 主题与 `ChekiAppShell`，稳定页面 ID 维护状态和返回；只注册真实可用页面。通用项目暂为「旧版项目」兼容入口，后续 v1.2.1 接入真实 Cheki 首页和记录；旧数据不自动映射。旧设置原值保留，R1 界面不沿用旧单色主题或虚假个人信息入口。中文系统文案使用固定 Flutter SDK 自带的 localizations；设置内可查应用版本、来源和完整 Apache 许可。源码接入和本地检查不等于已构建或安装最新 APK。

成员管理与登记复用 `member_inputs.dart`：`MemberColorField` 先局部预览，只有确认才向表单返回颜色；取消或系统返回不改原值。`MemberMultiSelectField` 使用稳定成员 ID，打开可搜索多选面板，姓名带团体前缀和配置色，确认才返回选择，外部表单保留草稿。停用或缺失的原选择明确提示、保持 ID，只有用户移除才删除。控件本身不持久化；当前管理页由 `IdentityStore` 实际保存，后续记录服务在自己的写事务内调用 `IdentityStore.selectionIn` 重新检查存在、停用和同人身份，不能嵌套开启新事务。颜色面板有标准 RGB 滑块补充画布交互，Widget 语义检查不代表 Android TalkBack 已验收。

管理内「成员」与「同人关联」均使用实际数据库。新成员可先不关联，再明确选择同人标签；同名不合并。转团先给原身份设置同人关联，随后创建新团身份、保留原关联与颜色，原身份不自动停用；需要停用时独立确认。改名与颜色、停用和关联修改都留审计，动作时间不是艺名实际生效日的推断。记录表引入后还须在关联修改事务内检查已有联合记录，禁止把同一张中的两个身份关联为同一人。

源码存储在application documents下的app_flutter/user_database.db。M0 候选使用 schema 2，当前 M1 开发源码使用 schema 4，旧导出为 schema 1；新增迁移账本及团体/尺寸/身份表，但不转换旧四表事实。完整机制及后续字段审查见 [数据版本指导](STORAGE.md)。
迁移包括四张业务表、sqlite_sequence、SharedPreferences设置、适用journal/WAL，保留时间戳ID与ext。
项目count是子项目数，子项目count需核对其明细数量。发现不一致报告，不自动修复。
备份使用SQLite一致快照或正确处理事务附属文件，不能复制运行中单文件宣称完整。
price目前TEXT；金额精度变更另定义兼容/回滚，不在UI修复中顺便改事实。
新字段需检查helper/model/page/statistics/cache/backup/migration全部消费者。
冷启动、数据核对、真实恢复和UI逐项验收；安装成功不等于全通过。
公开发布需要发布授权和许可声明；流程建立不证明产品可构建，静态脚本存在不证明APK已签名。

属性和扣券明细以 [WF-010 最新属性修订](requirements/CHEKI_ATTRIBUTES_20261011.md) 为准：勾选式三选一，默认有签；背签仅有签可用，切换清除禁用；扣券明细常开。真实迁移遇旧冲突组合保留原事实并预览映射。
