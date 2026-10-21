# Build from the repo root so the shared exercise seed is included:
#   docker build -f ai_service/Dockerfile -t forme-ai .
ARG BASE_IMAGE=python:3.13-slim
FROM ${BASE_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080
WORKDIR /app
COPY ai_service/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY ai_service/app ./app
COPY ai_service/prompts ./prompts
COPY seed ./seed
RUN useradd -r -u 10001 forme && chown -R forme /app
USER forme
# concurrency 10 per instance (Cloud Run), 2 workers on 2 vCPU
CMD exec uvicorn app.main:app --host 0.0.0.0 --port ${PORT} --workers 2 --timeout-keep-alive 65
