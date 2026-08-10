# 参与开发

项目采用“AI 负责日常产品与技术领导、Codex 负责执行、项目所有者负责最终业务验收和高风险授权”的协作方式。提交代码前请先创建产品需求或问题 Issue，确保目标、风险和验收标准明确。

## Pull Request 要求

- 从独立分支提交，不直接修改 `main`。
- 一个 Pull Request 只处理一个主题。
- 更新受影响的测试和文档。
- 说明用户影响、兼容风险和恢复方式。
- 完成本地发布门禁并等待 GitHub CI。
- 真实服务行为变化需在专用测试服务器验收。

完整流程参见 [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)，架构边界参见 [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)。
