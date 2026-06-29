FROM python:3.10-slim

# Create a non-root user
RUN useradd -u 10001 -m appuser
WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY app.py .

# Switch to non-root user
USER appuser

CMD ["python", "app.py"]
