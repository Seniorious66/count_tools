# M0 本地工程备份与恢复

这是 M0 的工程操作入口，不是 App 内的备份页面。日常用户入口仍按 M2 的 UI-05 实施。工具只允许恢复到新建并带项目标记的仓库外隔离目录，不能覆盖手机或原始系统导出。

## 数据包契约

格式 1 是一个完整目录：`database.sqlite`、`settings/` 下的原始全设置文件、`attachments/` 中的附属证据及 `manifest.json`。SQLite 使用在线 backup API 获取一致的已提交图像，包含已提交 WAL；不会只复制运行中的主库文件。数据库中全部表、序列、字段、NULL、BLOB、未知表/字段、索引和视图保留。清单记录文件与全表核验信息，命令输出仅显示数量和结果，不打印设置值、用户密钥或文件摘要。

设置接受 Android 的完整 SharedPreferences XML 或完整偏好 JSON，原始字节原样携带，未知键不删除。JSON 的列表必须是字符串列表。无法理解的格式拒绝，先保留原料并扩展检查器。当前业务检查支持旧 schema 1；后续 schema 包同步扩展，不能只凭“全部文件已复制”认定新业务正确。

输入使用已导出的静止副本或已停写的完整数据集。SQLite 快照可以处理提交中的 WAL，但这不意味着电脑工具能原子冻结运行中 App 的数据库和设置。不要用它对正在改动的设置声称同时点完整备份。系统原 ZIP/BAK/TAR/APK 等保持在原 E/NAS 快照中；本工具不修改它们。journal/WAL 等作为原始附件保留，恢复一致快照时**不会重新应用原 journal/WAL**，防止把旧事务施加到新快照。

## 可操作步骤

将下列占位路径替换为合成测试集或仓库外导出副本。`python` 需为已配置的 Python 3.13 或以上运行时。所有操作都在电脑进行。

```powershell
python scripts/recovery.py snapshot --database '<静止副本/db>' --settings '<完整设置.xml或json>' --attachment '<适用附属文件>' --output '<新的备份目录>'
python scripts/recovery.py verify --bundle '<备份目录>'
python scripts/recovery.py init --root '<尚不存在的隔离根目录>'
python scripts/recovery.py preview --bundle '<备份目录>' --root '<隔离根目录>'
python scripts/recovery.py restore --bundle '<备份目录>' --root '<隔离根目录>' --apply
python scripts/recovery.py verify --bundle '<隔离根目录/current>'
```

附件可重复指定。已有备份、已有初始化目标、未标记或其他项目目录都拒绝覆盖。预览核对新旧 schema、各表数量、设置数量和完整文件校验，不展示私密值；预览不改原代数据。恢复后可将 `current/database.sqlite` 和设置作为隔离重开输入。恢复是整代替换，绝不把旧库解释成 Cheki 或自动合并记录。

## 回滚与进程中断

新代在目标同盘目录准备、预检后才切换。旧 `current` 改名保留为 `.rollback-…`，再切入新代；数据库、设置和附属文件随同一个目录一起切换。提交前的故障回到原代；失败的新代和未完成暂存保留，便于排查。持久事务标记加文件锁防止重复切换；进程退出会释放操作锁。

若进程在切换中退出，先执行：

```powershell
python scripts/recovery.py recover --root '<隔离根目录>'
```

未提交事务恢复原代；已提交事务校验并保留新代。提交完成但清理事务标记失败时返回 `cleanup_pending=true`，数据提交已完成，下次先运行 recover。缺失原代、无效标记或校验失败时停止并保留材料，不猜测或删除。当前测试证明进程中断恢复；不能把它解释为已经验证所有断电、磁盘损坏或手机厂商行为。

自动验收 `python scripts/test-recovery.py -v` 使用一次性合成目录，覆盖 WAL/未提交事务、完整字段/序列/未知值、设置、只读预览、损坏拒绝、切换故障、实际子进程退出后的新进程恢复，以及原代保留。它不会访问真实备份。
