# CDO SRE Dashboard Frontend

Base Vite React app for frontend design agent.

## Run

Backend first:

```bash
cd ../
docker compose up --build
```

Frontend:

```bash
cd frontend
npm install
npm run dev
```

Open `http://127.0.0.1:5173`.

Vite proxies `/api` and `/health` to `http://127.0.0.1:8001`, so browser never needs AWS credentials or CORS changes.

## Contract

Use `../FRONTEND_HANDOFF.md` as source of truth.

Hard rules:

- no AWS SDK in browser
- no credentials in localStorage/sessionStorage/cookies
- no raw PromQL builder/input
- no SQS message receive UI
