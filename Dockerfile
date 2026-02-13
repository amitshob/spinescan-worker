# Stage 1: OpenMVS tools
FROM openmvs/openmvs-ubuntu:latest AS openmvs

# Stage 2: CPU-only COLMAP
FROM graffitytech/colmap:3.8-cpu-ubuntu22.04

# Install a complete Python + venv + locales
RUN apt-get update && apt-get install -y \
    python3-full python3-venv python3-pip \
    locales bash \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Copy OpenMVS binaries
COPY --from=openmvs /usr/bin/ /opt/openmvs/usr_bin/
COPY --from=openmvs /usr/local/bin/ /opt/openmvs/usr_local_bin/
ENV PATH="/opt/openmvs/usr_bin:/opt/openmvs/usr_local_bin:${PATH}"

# Create venv and install deps
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
