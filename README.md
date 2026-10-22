# docker-images-sync
通过 GitHub Actions 定时拉取 DockerHub 镜像至 ghcr.io，加速 Docker 镜像拉取流程。

## 同步规则

- 推送到 `main`、每天 `07:00 UTC`（北京时间 `15:00`）或手动触发时同步。
- 固定版本标签已存在于 GHCR 时直接跳过，不重新推送，也不改动其元数据。
- `latest` 标签会比较源镜像与 GHCR 的 digest，仅在发生变化时更新。
- 镜像仅同步 `linux/amd64` 版本。
- 如果查询 GHCR 时发生网络或鉴权错误，任务会失败，不会覆盖已有镜像。

固定版本标签已存在时会严格跳过；新增标签和后续 `latest` 更新只同步 `linux/amd64`。

## 多标签配置

同一个镜像可以同步多个标签：

```yaml
- name: nginx
  source: nginx
  tag:
    - "1.30.5"
    - "stable"
    - "latest"
```

每个标签会独立检查 GHCR 中是否存在。固定标签已存在时跳过，`latest` 仅在 digest 变化时更新。原来的单标签写法仍然有效：

```yaml
- name: nginx
  source: nginx
  tag: 1.30.5
```
