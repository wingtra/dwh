# HubSpot Source Pipeline

This folder contains the independently deployable HubSpot CRM ingestion
pipeline.

## Contents

- `src/` - HubSpot API extraction, raw GCS landing, BigQuery staging, extract logs, current mirrors, and watermarks
- `infra/` - setup, deploy, scheduler, and monitoring scripts
- `docs/` - implementation plan and operational overview
- `cloudbuild.yaml` - Cloud Build image build/push definition

## V1 Scope

- Enabled objects: contacts, companies, deals, products, line items, quotes
- Enabled custom objects: licences (objectTypeId `2-1022441`, one record per
  license; source of the RevOps "[Accruals] ARR: Raw Data" report). Requires
  the `crm.objects.custom.read` scope on the service key. The licence-to-deal
  link is carried by the `associated_deal_id` property, so no association
  resource is needed.
- Deferred object: tickets. HubSpot service keys currently return
  `MISSING_SCOPES` for tickets, so tickets stay in the manifest but are
  excluded from the default scheduled run.
- Metadata: owners, pipelines, pipeline stages, object schemas, object properties
- Enabled associations: contact-company, contact-deal, company-deal,
  deal-line item, quote-deal, quote-line item, product-line item

## Auth

Use a HubSpot service key stored in Secret Manager as `hubspot-service-key`.
The loader reads the key at runtime and sends it as a bearer credential.

## Common Commands

Run from this folder unless noted otherwise:

```bash
python -m unittest discover -s tests
infra/setup.sh
infra/deploy.sh
infra/setup_scheduler.sh
infra/setup_monitoring.sh you@example.com
```

Do not run the infra scripts until the cloud/IAM baseline and intended mutation
delta have been reviewed and approved.

Current design is documented in [docs/pipeline-overview.md](docs/pipeline-overview.md)
and [docs/implementation-plan.md](docs/implementation-plan.md).
