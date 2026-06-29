# Shared Pipeline Helpers

Put shared ingestion helpers here only after duplication is concrete across
multiple source pipelines.

Good candidates:
- logging conventions
- run metadata helpers
- BigQuery load utilities
- Secret Manager helpers
- deployment script helpers

Do not put source-specific extraction behavior here.
