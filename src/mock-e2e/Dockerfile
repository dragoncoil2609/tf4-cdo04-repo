FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --no-cache-dir boto3 requests

COPY app.py /app/app.py
WORKDIR /app

ENV MOCK_ROLE=api
EXPOSE 8080

CMD ["python", "app.py"]
