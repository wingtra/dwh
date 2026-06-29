# Pipelines

Each source under `pipelines/sources/` is an independently deployable ingestion
pipeline. It can have its own Cloud Run Job, scheduler, Docker image, secrets,
IAM, monitoring, and runbook.

Keep source-specific behavior inside the source folder. Move code to
`pipelines/shared/` only after at least two pipelines need the same concrete
helper.

Recommended source layout:

```text
pipelines/sources/<source>/
  src/
  infra/
  docker/
  docs/
  Dockerfile
  requirements.txt
```
