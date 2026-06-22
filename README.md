# TF4 Foresight Lens - CDO Repo

Repo skeleton cho nhóm Cloud/DevOps trong Task Force 4.

## Source of truth

- `docs/`: 7 CDO documents required by Evidence Pack.
- `contracts/`: 3 AI-CDO contracts to review/sign/freeze in W11.
- `infra/`: IaC/platform implementation.
- `src/`: application/integration code.
- `tests/`: test code and scenario runners.
- `evidence/`: screenshots, logs, reports, links, command outputs.
- `scripts/`: helper scripts for local runs, tests, and evidence collection.

## Required CDO documents

- `docs/01_requirements_analysis.md`
- `docs/02_infra_design.md`
- `docs/03_security_design.md`
- `docs/04_deployment_design.md`
- `docs/05_cost_analysis.md`
- `docs/07_test_eval_report.md`
- `docs/08_adrs.md`

## Required contracts

- `contracts/telemetry-contract.md`
- `contracts/ai-api-contract.md`
- `contracts/deployment-contract.md`

## Mentor checkpoint rules

- Docs live in repo as Markdown.
- Git history is process evidence.
- T5 W11 freezes the 3 AI-CDO contracts.
- W12 T3 must call the real AI endpoint.
- Code freeze is 8h T5 02/07/2026.
- Curveball responses go in `evidence/curveball-responses.md`.
