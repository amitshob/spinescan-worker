# ---- Stage 1: OpenMVS donor ----
FROM openmvs/openmvs-ubuntu:latest AS openmvs

# ---- Stage 2: COLMAP donor (CPU-only) ----
FROM graffitytech/colmap:3.8-cpu-ubuntu22.04 AS colmap

# ---- Stage 3: Final runtime ----
FROM ubuntu:22.04

# Force reset of all Python variables to ensure a clean slate
ENV PYTHONHOME=
ENV PYTHONPATH=
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# 1. Install system dependencies first
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash locales \
    python3 python3-venv python3-pip \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libfreeimage3 \
    libopencv-core4.5 libopencv-imgcodecs4.5 libopencv-imgproc4.5 \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    libglew2.2 libglfw3 \
    && locale-gen en_US.UTF-8 \
    && rm -rf /var/lib/apt/lists/*

# 2. CREATE THE VENV NOW (Before copying potential donor "poison")
# This ensures the venv is built using the pure Ubuntu 22.04 Python
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

# 3. Copy binaries from donors into ISOLATED /opt folders
# DO NOT copy into /usr/local directly to avoid overwriting system libs
COPY --from=colmap /usr/local/bin/ /opt/colmap/bin/
COPY --from=colmap /usr/local/lib/ /opt/colmap/lib/
COPY --from=openmvs /usr/bin/ /opt/openmvs/bin/
COPY --from=openmvs /usr/local/lib/ /opt/openmvs/lib/

# 4. Update paths to point to our isolated /opt folders
ENV PATH="/opt/colmap/bin:/opt/openmvs/bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/colmap/lib:/opt/openmvs/lib:${LD_LIBRARY_PATH}"

WORKDIR /app
COPY requirements.txt .
# Pip is now the one inside /opt/venv/bin
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
