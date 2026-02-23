# =========================
# SpineScan Worker Dockerfile (STABLE + DEBUGGABLE)
# Build COLMAP (CPU) + OpenMVS from source on Ubuntu 22.04
# =========================

# ---------- Stage 1: Build COLMAP + OpenMVS ----------
FROM ubuntu:22.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential cmake ninja-build pkg-config \
    python3 python3-dev python3.10-dev \
    libboost-filesystem-dev libboost-graph-dev libboost-program-options-dev libboost-system-dev \
    libeigen3-dev libflann-dev libfreeimage-dev libmetis-dev \
    libgflags-dev libgoogle-glog-dev libsqlite3-dev \
    libglew-dev \
    qtbase5-dev libqt5opengl5-dev \
    libceres-dev \
    libopencv-dev \
    libpng-dev libjpeg-dev libtiff-dev \
    libtbb-dev \
    libgl1-mesa-dev libglu1-mesa-dev \
    libcgal-dev libgmp-dev \
    libvtk9-dev \
    libboost-iostreams-dev libboost-serialization-dev \
    libatlas-base-dev \
    && rm -rf /var/lib/apt/lists/*

ARG COLMAP_TAG=3.9
RUN git clone --depth 1 --branch ${COLMAP_TAG} https://github.com/colmap/colmap.git /tmp/colmap
RUN cmake -S /tmp/colmap -B /tmp/colmap/build -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/colmap \
    -DGUI_ENABLED=OFF \
    -DCUDA_ENABLED=OFF
RUN cmake --build /tmp/colmap/build --target install -- -j2

# VCG (vcglib) required by OpenMVS
RUN git clone --depth 1 https://github.com/cdcseacave/VCG.git /tmp/vcglib

ARG OPENMVS_TAG=v2.3.0
RUN git clone --recurse-submodules --branch ${OPENMVS_TAG} https://github.com/cdcseacave/openMVS.git /tmp/openmvs
RUN cd /tmp/openmvs && git submodule update --init --recursive

RUN set -eux; \
    rm -rf /tmp/openmvs/build_out; \
    mkdir -p /tmp/openmvs/build_out; \
    ( cmake -S /tmp/openmvs -B /tmp/openmvs/build_out -GNinja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/openmvs \
        -DVCG_ROOT=/tmp/vcglib \
        -DOpenMVS_USE_CUDA=OFF \
        -DOpenMVS_USE_OPENMP=ON \
      2>&1 | tee /tmp/openmvs_configure.log ); \
    ec=${PIPESTATUS[0]}; \
    if [ "$ec" -ne 0 ]; then \
      echo "==== OpenMVS CMake configure FAILED (exit=$ec) ===="; \
      tail -n 200 /tmp/openmvs_configure.log || true; \
      cat /tmp/openmvs/build_out/CMakeFiles/CMakeError.log || true; \
      cat /tmp/openmvs/build_out/CMakeFiles/CMakeOutput.log || true; \
      exit "$ec"; \
    fi

RUN cmake --build /tmp/openmvs/build_out --target install -- -j2

# ---------- Stage 2: Runtime ----------
FROM ubuntu:22.04 AS runtime
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash \
    python3 python3-venv python3-pip \
    libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-program-options1.74.0 libboost-system1.74.0 \
    libboost-iostreams1.74.0 libboost-serialization1.74.0 \
    libceres2 libgflags2.2 libgoogle-glog0v5 \
    libfreeimage3 libglew2.2 \
    libsqlite3-0 \
    libopencv-core4.5d libopencv-imgproc4.5d libopencv-imgcodecs4.5d \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    libtbb2 \
    libgl1-mesa-glx libglu1-mesa \
    libvtk9.1 \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV QT_QPA_PLATFORM=offscreen

COPY --from=builder /opt/colmap /opt/colmap
COPY --from=builder /opt/openmvs /opt/openmvs

ENV PATH="/opt/colmap/bin:/opt/openmvs/bin:${PATH}"

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

# Quick sanity checks (fail fast if something is off)
RUN colmap -h >/dev/null 2>&1

# ---- Sanity checks ----
RUN set -eux; \
    colmap -h >/dev/null 2>&1; \
    echo "[runtime] colmap OK"

RUN set -eux; \
    ls -lah /opt/openmvs/bin || true; \
    /opt/openmvs/bin/InterfaceCOLMAP -h >/dev/null 2>&1; \
    echo "[runtime] InterfaceCOLMAP OK"


CMD ["python", "-u", "worker/main.py"]
