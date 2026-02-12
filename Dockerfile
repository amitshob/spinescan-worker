FROM colmap/colmap:latest

RUN apt-get update && apt-get install -y \
    python3 python3-venv python3-pip bash \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Create and use a venv to satisfy PEP 668
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
