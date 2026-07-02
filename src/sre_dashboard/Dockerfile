FROM python:3.10-slim

# Install Terraform CLI for Terraform output discovery.
ARG TERRAFORM_VERSION=1.9.8
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip \
    && unzip /tmp/terraform.zip -d /usr/local/bin/ \
    && rm /tmp/terraform.zip

RUN useradd -u 10001 -m appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . /app/sre_dashboard
ENV PYTHONPATH=/app

USER appuser
EXPOSE 8001

CMD ["uvicorn", "sre_dashboard.app:app", "--host", "0.0.0.0", "--port", "8001"]
