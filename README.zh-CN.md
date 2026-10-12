---
docType: repo-entry
scope: repo
status: current
authoritative: true
owner: database
language: zh-CN
whenToUse: "开始使用天工 AI 数据库项目时。"
whenToUpdate: "项目用途、目录或开发入口变化时。"
checkPaths: [README.md, supabase/**, scripts/**, tests/**]
lastReviewedAt: 2026-10-11
lastReviewedCommit: a38d22f
---

# 天工 AI 数据库

本项目管理 **Tiangong AI knowledge-base 的 PostgreSQL / Supabase 数据库源码**。
首批迁入 KB 原有的 35 个 migrations 和 16 个 SQL smoke tests，保留文件名、原始字节、
来源 commit 和 SHA-256。补回一份已在线上执行的 KB hotfix，以及两个明确注明用途的
benchmark 历史记录后，随后第 39 个迁移以只读 schema 捕获补齐历史应用对象。LCA database 仅作为工具流程参考，
没有迁入 LCA 业务数据库。

需要 Python 3.11+、Docker 和 Supabase CLI **2.120.0**。离线工具无需第三方 Python 包。

```sh
python3 -m unittest discover -s tests -p 'test_*.py'
scripts/test-database.sh
```

- `supabase/migrations/`：数据库迁移的唯一可写来源。
- `tests/sql/`：数据库 SQL 测试。
- `supabase/workspace/`：可再生成的数据库对象视图，以及保留手工修改的 changes 目录。
- `scripts/`：schema 导出、对象拆分、迁移生成、类型生成与本地验证。
- `docs/source-inventory.json`：迁入文件的来源与摘要。

源码已覆盖捕获时的 24 张 public 应用表、72 个函数和 11 个枚举；不含业务数据、
Auth 用户、角色密码或成员身份。目录一致性与真实消费者验证见
[基线说明](docs/legacy-schema-baseline.md)，平台管理对象的边界见[架构](docs/architecture.md)。KB 的应用和采集代码仍留在 knowledge-base 仓库。

开发分支和 PR 目标均为 `main`。CI 验证本地临时数据库；Knowledge Base 项目通过
[Supabase GitHub Integration](docs/supabase-integration.md)连接新仓库，启用前先完成
预览验证和历史账本对齐，任务记录保留实际配置与部署证据。
已有数据库的 KB migration ledger 与 Supabase CLI ledger 不能混用；操作前阅读
[开发流程](docs/development.md)和[验证要求](docs/validation.md)。
