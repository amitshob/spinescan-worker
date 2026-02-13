# Stage 1: OpenMVS tools (we'll copy binaries out of this image)
FROM openmvs/openmvs-ubuntu:latest AS openmvs

# Stage 2: CPU-only COLMAP (no CUDA)
FROM graffitytech/colmap:3.8-cpu-ubuntu22.04

# Install Python + venv + pip (PEP 668 safe)
RUN apt-get update && apt-get install -y \
    python3 python3-venv python3-pip bash \
    && rm -rf /var/lib/apt/lists/*

# Copy OpenMVS binaries into this image (paths vary by image, so copy both)
COPY --from=openmvs /usr/bin/ /opt/openmvs/usr_bin/
COPY --from=openmvs /usr/local/bin/ /opt/openmvs/usr_local_bin/

# Ensure OpenMVS tools are on PATH
ENV PATH="/opt/openmvs/usr_bin:/opt/openmvs/usr_local_bin:${PATH}"

# Python venv
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
