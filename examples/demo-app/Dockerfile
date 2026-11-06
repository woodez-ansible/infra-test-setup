FROM python:3.13-slim

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} PYTHONUNBUFFERED=1

WORKDIR /app
COPY app.py .

# Numeric UID so Kubernetes can verify runAsNonRoot
USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
