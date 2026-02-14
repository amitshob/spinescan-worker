# ---- Stage 1: OpenMVS donor ----
FROM openmvs/openmvs-ubuntu:latest AS openmvs

# ---- Stage 2: COLMAP donor (CPU-only) ----
FROM graffitytech/colmap:3.8-cpu-ubuntu22.04 AS colmap

# ---- Stage 3: Final runtime (stable Python) ----
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Install Python FIRST before any COPY operations
RUN apt-get update && apt-get install -y \
    ca-certificates bash \
    python3-full python3-venv python3-pip \
    locales \
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libfreeimage3 \
    libopencv-core4.5 libopencv-imgcodecs4.5 libopencv-imgproc4.5 \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    libglew2.2 libglfw3 \
    && rm -rf /var/lib/apt/lists/*

# Ensure UTF-8 locale
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Test Python BEFORE copying anything
RUN python3 -c "import site; import sys; print('Python OK before COPY:', sys.version)"

# Copy everything from donor images to separate staging areas
COPY --from=colmap /usr/local/ /tmp/colmap_files/
COPY --from=openmvs /usr/bin/ /tmp/openmvs_usr_bin/
COPY --from=openmvs /usr/local/bin/ /tmp/openmvs_usr_local_bin/
COPY --from=openmvs /usr/local/lib/ /tmp/openmvs_usr_local_lib/

# Move only what we need, excluding Python-related files
RUN mkdir -p /opt/colmap/bin /opt/colmap/lib && \
    mkdir -p /opt/openmvs/bin /opt/openmvs/lib && \
    # Copy COLMAP binaries
    if [ -d /tmp/colmap_files/bin ]; then \
      cp -r /tmp/colmap_files/bin/* /opt/colmap/bin/ 2>/dev/null || true; \
    fi && \
    # Copy COLMAP libs (but skip Python)
    if [ -d /tmp/colmap_files/lib ]; then \
      find /tmp/colmap_files/lib -name "*.so*" ! -path "*/python*" -exec cp -d {} /opt/colmap/lib/ \; 2>/dev/null || true; \
    fi && \
    # Copy OpenMVS binaries
    cp /tmp/openmvs_usr_local_bin/* /opt/openmvs/bin/ 2>/dev/null || true && \
    # Copy OpenMVS libs (but skip Python)
    find /tmp/openmvs_usr_local_lib -name "*.so*" ! -path "*/python*" -exec cp -d {} /opt/openmvs/lib/ \; 2>/dev/null || true && \
    # Clean up temp files
    rm -rf /tmp/colmap_files /tmp/openmvs_usr_bin /tmp/openmvs_usr_local_bin /tmp/openmvs_usr_local_lib

# Put tools on PATH
ENV PATH="/opt/colmap/bin:/opt/openmvs/bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/colmap/lib:/opt/openmvs/lib:${LD_LIBRARY_PATH}"

# CRITICAL: Run Qt in headless mode (no display)
ENV QT_QPA_PLATFORM=offscreen

# Test Python AFTER copying
RUN python3 -c "import site; import sys; print('Python OK after COPY:', sys.version)"

# Python venv
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
