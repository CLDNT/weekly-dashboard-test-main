# A-1 Deployment & Rollback Runbook (DEV account 604775478093)

**Date:** 2026-09-07
**Change:** A-1 (Critical) — SPICE refresh verification + fatal/alarm on failure; A-2 slice (add `kpi-staff-weekly-prod`, `kpi-practice-weekly-prod` to SSOT); migration 108 (`spice_refresh_log` + freshness views); SPICE freshness dashboard tile.
**Account:** DEV showcase **604775478093**, us-east-1. **NOT production.**
**Scope:** code-only Lambda update + one additive DB migration + one QuickSight dataset/tile. No CloudFormation deploy (avoids IaC-drift risk).

---

## Pre-change baseline (for rollback)

| Item | Value |
|---|---|
| Lambda | `production-clockify-import` |
| Pre-A-1 CodeSha256 | `8GanbiQh+/QBr+Z9AHIezwqV/8UjrxLxCGzpD19e1QM=` |
| Pre-A-1 RevisionId | `f7a06666-bd0f-4975-8d8a-d0837c737296` |
| Pre-A-1 code backup (S3) | `s3://weekly-reporting-production-deployments-604775478093/lambda/backups/pre-a1-20260907-211517-sha8Ganbi.zip` |
| CFN stack (unchanged) | `weekly-reporting-production` |

Migration 108 is **additive only** (new table + new views). It does not alter or drop any existing table/view, so it is safe and does not require a data rollback. Reversal (if ever needed) = `DROP VIEW vw_spice_freshness_summary, vw_spice_freshness; DROP TABLE spice_refresh_log;`

---

## Forward steps (executed)

1. Back up live Lambda code to S3 (done — see backup key above).
2. Apply migration 108 via Lambda: `{"mode":"run_migration","migration_file":"108_spice_refresh_log.sql"}`.
3. Build runtime-correct zip (py3.11 / manylinux2014_x86_64) and `update-function-code` on `production-clockify-import`.
4. Run one incremental pipeline in dev and verify: `spice_refresh_log` populates, staff/practice datasets refresh, email/summary reports accurate succeeded/failed.
5. Create `spice-freshness` QuickSight dataset over `vw_spice_freshness_summary` + add tile to the dev KPI dashboard (analysis definition backed up first to `/tmp/` and S3).

---

## ROLLBACK

### Roll back the Lambda code (restores pre-A-1 behaviour)
```bash
aws lambda update-function-code \
  --function-name production-clockify-import \
  --s3-bucket weekly-reporting-production-deployments-604775478093 \
  --s3-key lambda/backups/pre-a1-20260907-211517-sha8Ganbi.zip \
  --region us-east-1 --publish
aws lambda wait function-updated --function-name production-clockify-import --region us-east-1
# Confirm SHA is back to 8GanbiQh+/QBr+Z9AHIezwqV/8UjrxLxCGzpD19e1QM=
aws lambda get-function-configuration --function-name production-clockify-import \
  --region us-east-1 --query CodeSha256 --output text
```

### Roll back migration 108 (optional — additive, usually leave in place)
```bash
aws lambda invoke --function-name production-clockify-import --region us-east-1 \
  --cli-binary-format raw-in-base64-out \
  --payload '{"mode":"run_query_master","sql":"DROP VIEW IF EXISTS vw_spice_freshness_summary; DROP VIEW IF EXISTS vw_spice_freshness; DROP TABLE IF EXISTS spice_refresh_log;"}' \
  /tmp/rollback108.json && cat /tmp/rollback108.json
```

### Roll back the dashboard tile
Restore the analysis definition backed up in step 5, or delete the added `spice-freshness` dataset + visual. The KPI analysis definition backup is saved to both `/tmp/kpi-analysis-backup-<ts>.json` and the deployment bucket under `lambda/backups/`.

**Concrete artifacts created (2026-09-07):**
- Analysis backup: `s3://weekly-reporting-production-deployments-604775478093/lambda/backups/kpi-analysis-backup-20260907-213829.json` (also `/tmp/kpi-analysis-backup-20260907-213829.json`).
- New SPICE dataset: `spice-freshness` (over `vw_spice_freshness_summary`).
- Analysis `kpi-tracking-analysis-dev`: added sheet `sheet-kpi-freshness` ("Data Freshness") + dataset identifier `spice_freshness`.
- Dashboard `kpi-tracking-dashboard-dev`: published version **4** (prior published version was 2 → **rollback = republish v2**).

**Rollback the tile:**
```bash
# Republish the prior dashboard version (pre-tile)
aws quicksight update-dashboard-published-version \
  --aws-account-id 604775478093 --dashboard-id kpi-tracking-dashboard-dev \
  --version-number 2 --region us-east-1
# Restore the analysis definition from backup
aws quicksight update-analysis --aws-account-id 604775478093 \
  --analysis-id kpi-tracking-analysis-dev --name "KPI Tracking Analysis (prod)" \
  --theme-arn arn:aws:quicksight::aws:theme/CLASSIC \
  --definition "$(python3 -c "import json;print(json.dumps(json.load(open('/tmp/kpi-analysis-backup-20260907-213829.json'))['Definition']))")" \
  --region us-east-1
# Optionally delete the dataset
aws quicksight delete-data-set --aws-account-id 604775478093 --data-set-id spice-freshness --region us-east-1
```

### Roll back the A-2 SSOT additions (if the extra refreshes cause issues)
The two added dataset IDs (`kpi-staff-weekly-prod`, `kpi-practice-weekly-prod`) are only in the new code. Rolling back the Lambda code (above) also reverts the SSOT list.

---

## Verification checklist after rollback
- [ ] `CodeSha256` == `8GanbiQh+/QBr+Z9AHIezwqV/8UjrxLxCGzpD19e1QM=`
- [ ] `aws lambda get-function-configuration` shows `LastUpdateStatus: Successful`, `State: Active`
- [ ] A dry `{"mode":"diagnose"}` invoke returns 200

---

## IAM change (required by A-1 verification)

The new verified refresh calls `quicksight:DescribeIngestion`, which the Lambda
execution role `production-lambda-execution-role` did not previously have (the
old fire-and-forget code never polled). Added to inline policy `QuickSightRefresh`:
`quicksight:DescribeIngestion` + `quicksight:CancelIngestion` on
`dataset/*` and `dataset/*/ingestion/*`.

**Original policy (for rollback)** — 2 actions block was:
`quicksight:CreateIngestion, quicksight:DescribeDataSet, quicksight:ListIngestions` on `dataset/*`.

### Rollback the IAM change
```bash
cat > /tmp/qs-orig.json <<'JSON'
{"Version":"2012-10-17","Statement":[
 {"Action":["quicksight:CreateIngestion","quicksight:DescribeDataSet","quicksight:ListIngestions"],
  "Resource":"arn:aws:quicksight:us-east-1:604775478093:dataset/*","Effect":"Allow"},
 {"Action":["quicksight:UpdateAnalysis","quicksight:DescribeAnalysis","quicksight:DescribeAnalysisDefinition"],
  "Resource":"arn:aws:quicksight:us-east-1:604775478093:analysis/*","Effect":"Allow"}]}
JSON
aws iam put-role-policy --role-name production-lambda-execution-role \
  --policy-name QuickSightRefresh --policy-document file:///tmp/qs-orig.json
```

### IaC reconciliation (REQUIRED before any prod CloudFormation deploy)
`cloudformation/template.yaml` defines this role's `QuickSightRefresh` policy.
It must be updated to include `quicksight:DescribeIngestion` (+ ingestion sub-resource
ARN) or a stack deploy will DROP this permission and re-break A-1. This is the
IaC-drift item — reconcile before promoting.

---

## Dev notification routing (for B-3/A-1 alert testing)

Dev Lambda `production-clockify-import` env updated to route alerts to the tester:
- `NOTIFICATION_TOPIC_ARN = arn:aws:sns:us-east-1:604775478093:production-weekly-reporting-notifications`
- `NOTIFICATION_RECIPIENTS = haider.ahmed@cloudelligent.com`
- SNS email subscription added for `haider.ahmed@cloudelligent.com` (SubscriptionArn `...:7dc504c7-74b7-4a95-9c17-558e9d3045a5`) — **pending email confirmation**.

These are **dev-only env vars / subscription**, not code changes — they do NOT affect prod.

### Rollback notification routing
```bash
# Remove the two env vars (re-set env without them), and unsubscribe:
aws sns unsubscribe --subscription-arn \
  arn:aws:sns:us-east-1:604775478093:production-weekly-reporting-notifications:7dc504c7-74b7-4a95-9c17-558e9d3045a5 \
  --region us-east-1
# Re-run update-function-configuration without NOTIFICATION_TOPIC_ARN / NOTIFICATION_RECIPIENTS if desired.
```

