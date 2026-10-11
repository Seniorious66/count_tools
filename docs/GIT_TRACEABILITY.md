# 本地提交与远端追溯

2026-10-11 WF-004：用户明确要求每次提交上传保证可追溯，构成本仓库持续的 commit/push 授权。目标只限个人 fork `https://github.com/Seniorious66/count_tools` 的 `personal/customization` 或其后代分支。上游不自动同步；不 force、不附带 tag，Release/APK 仍另授权。

## 首次克隆启用

Git 不会自动启用版本控制中的 hooks。每个新 checkout 先执行：

```powershell
git config --local core.hooksPath .githooks
# 如果默认 python 不适用，指定可运行标准库检查的外部 Python；路径用正斜线：
git config --local counttools.python 'C:/独立工具/python.exe'
```

本 checkout 已配置仓库 hooks 和现有外部 Python。GitHub 直连本轮失败，使用 Windows 已启用的 `127.0.0.1:7890` 代理；仅仓库本地 Git 配置使用此代理，未改变全局或系统配置。代理端口变更后按本机实际配置更新，不能把网络不可用记为上传成功。

## 每次提交

先读取四表，完成本轮约定的验证和日志；只暂存经过检查的路径，不把真实数据库、系统备份、APK、设置文件、密码或签名交给 Git。

```powershell
git diff
git diff --cached
.\scripts\commit-and-push.ps1 -Message '本轮实际变化的提交主题' -Paths @('具体文件1','具体文件2')
# 已有经过检查的暂存内容时，可以省略 -Paths。
```

`pre-commit` 检查个人分支/远端身份、暂存的个人数据和私钥，以及**暂存工作簿**的规划与已有 HEAD 历史。首个包含工作簿的提交建立后，每轮额外执行 `python scripts/verify-mastersheet.py --baseline HEAD`。它不代替产品测试。

`post-commit` 自动推送当前分支到个人 `origin`，然后查询远端分支与本地 HEAD 完全一致。推送收据写在 `.git/count-tools-push-state.json`，每次尝试追加 `.git/count-tools-push-history.jsonl`，内部提交标识不写入用户交付报告。

Git 的 post-commit 失败无法撤销已经完成的本地提交。提交入口因此还独立查询远端：上传未证实就报错，保留本地提交并重试：

```powershell
.\scripts\commit-and-push.ps1 -PushOnly
python scripts/git-trace.py verify
```

不绕过 hooks；若在其他工具中提交或配置未启用，交付前也必须明确推送并运行 `verify`。本地提交成功、Git push 返回成功、远端核对通过是分别有证据的状态。网络或认证失败时明确告知未上传，不能默默留下只在本机的提交。

## 本轮基线与数据备份

本轮将既有 WF-001–003 流程/需求/规划和 WF-004 改动建立首个 Git 基线；旧 Changelog 中“当时未提交”的记录保留，在本轮追加后续提交事实。闭合日志同样提交并推送。

真实数据两处路径与核验见 [设备及数据指导](MOBILE.md)。数据备份和源码 Git 追溯分别维护；向 Git 上传源码不会把手机私有数据库备份到 GitHub。

只读复核已有旧 schema 快照可执行：

```powershell
python scripts/verify-backup-copies.py --local 'E:\OneDrive\Code\artifacts\count-tools-export\20261011_102725' --nas '/srv/nas/hdd/Code/artifacts/count-tools-export/20261011_102725' --receipt 'E:\OneDrive\Code\artifacts\count-tools-export\一个新的核验收据名.json'
```

只有本轮用户确实确认备份后未修改时才加 `--user-confirmed-unchanged`；否则结果标为历史快照。脚本不连接手机、不复制、不恢复或写入真实库，仅比较两处已有文件。未来新 schema 按对应工作包扩展检查器。
