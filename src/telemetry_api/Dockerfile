FROM python:3.10-slim
WORKDIR /app
RUN apt-get update && apt-get install -y curl && rm -rf /var/lib/apt/lists/*
COPY requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY . /app/telemetry_api
EXPOSE 8080
CMD ["uvicorn", "telemetry_api.main:app", "--host", "0.0.0.0", "--port", "8080"]
