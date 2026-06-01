FROM ollama/ollama:0.6.1

USER root

ENV DEBIAN_FRONTEND=noninteractive
ENV OLLAMA_HOST=0.0.0.0:11434
ENV PORT=8080

RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    python3 \
    python3-pip \
    python3-venv \
    rsync \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/proxy-venv \
    && /opt/proxy-venv/bin/pip install --no-cache-dir fastapi uvicorn httpx
ENV PATH="/opt/proxy-venv/bin:${PATH}"

WORKDIR /app

COPY proxy.py /app/proxy.py
COPY start.sh /app/start.sh

RUN chmod +x /app/start.sh

EXPOSE 8080

ENTRYPOINT ["/bin/bash", "/app/start.sh"]
