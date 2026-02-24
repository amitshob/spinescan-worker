# ============================================================
# SpineScan Worker
# COLMAP + OpenMVS CPU build (stable for Render deployment)
# ============================================================

############################
# Stage 1 — Builder
############################
FROM ubuntu:22.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential cmake ninja-build pkg-config \
    python3 python3-dev python3.10-dev \
    \
    # COLMAP deps
    libboost-filesystem-dev libboost-graph-dev libboost-program-options-dev libboost-system-dev \
    libeigen3-dev libflann-dev libfreeimage-dev libmetis-dev \
    libgflags-dev libgoogle-glog-dev libsqlite3-dev \
    libglew-dev \
    qtbase5-dev libqt5opengl5-dev \
    libceres-dev \
    \
    # OpenMVS deps
    libopencv-dev \
    libpng-dev libjpeg-dev libtiff-dev \
    libtbb-dev \
    libgl1-mesa-dev libglu1-mesa-dev \
    libcgal-dev libgmp-dev \
    libvtk9-dev \
    libboost-iostreams-dev libboost-serialization-dev \
    libatlas-base-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Build COLMAP (CPU-only, no GUI, no CUDA) ---
ARG COLMAP_TAG=3.9
RUN git clone --depth 1 --branch ${COLMAP_TAG} https://github.com/colmap/colmap.git /tmp/colmap

RUN cmake -S /tmp/colmap -B /tmp/colmap/build -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/colmap \
    -DGUI_ENABLED=OFF \
    -DCUDA_ENABLED=OFF

RUN cmake --build /tmp/colmap/build --target install -- -j2

# --- VCG required by OpenMVS ---
RUN git clone --depth 1 https://github.com/cdcseacave/VCG.git /tmp/vcglib

# --- Build OpenMVS ---
ARG OPENMVS_TAG=v2.3.0
RUN git clone --recurse-submodules --branch ${OPENMVS_TAG} https://github.com/cdcseacave/openMVS.git /tmp/openmvs
RUN cd /tmp/openmvs && git submodule update --init --recursive

RUN set -eux; \
    mkdir -p /tmp/openmvs/build; \
    ( cmake -S /tmp/openmvs -B /tmp/openmvs/build -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/openmvs \
        -DVCG_ROOT=/tmp/vcglib \
        -DOpenMVS_USE_CUDA=OFF \
        -DOpenMVS_USE_OPENMP=ON \
      2>&1 | tee /tmp/openmvs_configure.log ); \
    ec=${PIPESTATUS[0]}; \
    if [ "$ec" -ne 0 ]; then \
      echo "===== OPENMVS CONFIGURE FAILED ====="; \
      tail -n 200 /tmp/openmvs_configure.log || true; \
      exit "$ec"; \
    fi

RUN cmake --build /tmp/openmvs/build --target install -- -j2

############################
# Stage 2 — Runtime
############################
FROM ubuntu:22.04 AS runtime
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash \
    python3 python3-venv python3-pip \
    \
    # COLMAP runtime libs
    libboost-filesystem1.74.0 libboost-graph1.74.0 \
    libboost-program-options1.74.0 libboost-system1.74.0 \
    libboost-iostreams1.74.0 libboost-serialization1.74.0 \
    libceres2 libgflags2.2 libgoogle-glog0v5 \
    libfreeimage3 libglew2.2 \
    libsqlite3-0 \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    \
    # OpenCV — full set that OpenMVS links against
    libopencv-core4.5d \
    libopencv-imgproc4.5d \
    libopencv-imgcodecs4.5d \
    libopencv-calib3d4.5d \
    libopencv-features2d4.5d \
    libopencv-flann4.5d \
    libopencv-highgui4.5d \
    libopencv-video4.5d \
    libopencv-videoio4.5d \
    \
    # OpenMVS runtime libs
    libtbb2 \
    libgl1-mesa-glx libglu1-mesa \
    libvtk9.1 \
    libcgal-dev \
    libgmp10 \
    libmpfr6 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV QT_QPA_PLATFORM=offscreen

COPY --from=builder /opt/colmap /opt/colmap
COPY --from=builder /opt/openmvs /opt/openmvs

# OpenMVS installs binaries under /opt/openmvs/bin/OpenMVS on Ubuntu builds
ENV OPENMVS_BIN="/opt/openmvs/bin/OpenMVS"

# Put tools on PATH (include the nested OpenMVS bin dir)
ENV PATH="/opt/colmap/bin:/opt/openmvs/bin:/opt/openmvs/bin/OpenMVS:${PATH}"

RUN echo "/opt/colmap/lib" > /etc/ld.so.conf.d/colmap.conf && \
    echo "/opt/openmvs/lib" > /etc/ld.so.conf.d/openmvs.conf && \
    ldconfig

RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app

COPY requirements.txt .
RUN set -eux; \
    pip install --no-cache-dir --progress-bar off -r requirements.txt; \
    echo "[runtime] pip install OK"

COPY worker ./worker
RUN chmod +x /app/worker/pipeline.sh

RUN set -eux; \
    colmap -h >/dev/null 2>&1; \
    echo "[runtime] colmap OK"

# Sanity: verify InterfaceCOLMAP links and runs cleanly.
# Show ldd output so missing libs are visible in build logs if it fails.
RUN set -eux; \
    echo "[runtime] /opt/openmvs/bin:"; ls -lah /opt/openmvs/bin || true; \
    echo "[runtime] /opt/openmvs/bin/OpenMVS:"; ls -lah /opt/openmvs/bin/OpenMVS || true; \
    echo "[runtime] ldd InterfaceCOLMAP:"; \
    ldd /opt/openmvs/bin/OpenMVS/InterfaceCOLMAP 2>&1 || true; \
    echo "[runtime] checking for missing libs:"; \
    ldd /opt/openmvs/bin/OpenMVS/InterfaceCOLMAP 2>&1 | grep "not found" && echo "MISSING LIBS ABOVE" && exit 1 || true; \
    LD_LIBRARY_PATH="/opt/openmvs/lib" /opt/openmvs/bin/OpenMVS/InterfaceCOLMAP -h 2>&1 || true; \
    echo "[runtime] InterfaceCOLMAP OK"

CMD ["python", "-u", "worker/main.py"]
