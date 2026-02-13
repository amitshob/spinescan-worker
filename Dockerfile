# ---- Stage 1: OpenMVS donor ----
FROM openmvs/openmvs-ubuntu:latest AS openmvs

# ---- Stage 2: COLMAP donor (CPU-only) ----
FROM graffitytech/colmap:3.8-cpu-ubuntu22.04 AS colmap

# ---- Stage 3: Final runtime ----
FROM ubuntu:22.04

# CRITICAL FIX: Overwrite inherited Python variables globally
# Setting them to empty strings here ensures the interpreter ignores donor-image paths
ENV PYTHONHOME=
ENV PYTHONPATH=
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Install dependencies
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

# Copy binaries from donors
COPY --from=colmap /usr/local/ /opt/colmap/
COPY --from=openmvs /usr/bin/ /opt/openmvs/usr_bin/
COPY --from=openmvs /usr/local/bin/ /opt/openmvs/usr_local_bin/
COPY --from=openmvs /usr/local/lib/ /opt/openmvs/usr_local_lib/

# Set up tool paths
ENV PATH="/opt/colmap/bin:/opt/openmvs/usr_bin:/opt/openmvs/usr_local_bin:${PATH}" \
    LD_LIBRARY_PATH="/opt/colmap/lib:/opt/openmvs/usr_local_lib:${LD_LIBRARY_PATH}"

# Create venv - The ENV resets above ensure this now works
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
