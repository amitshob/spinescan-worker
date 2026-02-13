# Prebuilt image that includes COLMAP + OpenMVS binaries
FROM raganwald/colmap-openmvs:latest

# Install Python + venv + pip
RUN apt-get update && apt-get install -y \
    python3 python3-venv python3-pip bash \
    && rm -rf /var/lib/apt/lists/*

# Python venv (PEP 668 safe)
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
