FROM mcr.microsoft.com/azurelinux/base/python:3.12

WORKDIR /app
COPY requirements.txt .
# --progress-bar off keeps pip's output plain ASCII. The fancy bar uses
# box-drawing characters that a cp1252 console cannot print.
RUN pip install --no-cache-dir --progress-bar off -r requirements.txt

COPY otel_setup.py .
COPY frontend/app.py .

# opentelemetry-instrument wraps the process and instruments Flask and requests
# without a line of code in app.py. It reads its configuration entirely from
# OTEL_* environment variables, and Container Apps injects the endpoint ones
# itself when the managed agent is enabled.
# No opentelemetry-instrument prefix: this app wires the SDK itself in
# otel_setup.py, so the sampler and the exporter are visible in the code.
# The prefixed form also works - see otel_setup.py.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--access-logfile", "-", "app:app"]
