# =========================
# SpineScan Worker Dockerfile (STABLE, LOW-RAM BUILD)
# Build COLMAP (CPU) + OpenMVS from source on Ubuntu 22.04
# =========================

# ---------- Stage 1: Build COLMAP + OpenMVS ----------
FROM ubuntu:22.04 AS builder
ARG DEBIAN_FRONTEND=noninteractive

# Force single-thread builds (critical for Render build memory)
ENV CMAKE_BUILD_PARALLEL_LEVEL=1
ENV MAKEFLAGS="-j1"

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    build-essential cmake ninja-build pkg-config \
    python3 python3-dev \
    # COLMAP deps
    libboost-filesystem-dev libboost-graph-dev libboost-program-options-dev libboost-system-dev \
    libeigen3-dev libflann-dev libfreeimage-dev libmetis-dev \
    libgflags-dev libgoogle-glog-dev libsqlite3-dev \
    libglew-dev \
    qtbase5-dev libqt5opengl5-dev \
    libceres-dev \
    # OpenMVS deps
    libopencv-dev \
    libpng-dev libjpeg-dev libtiff-dev \
    libtbb-dev \
    libgl1-mesa-dev libglu1-mesa-dev \
    libcgal-dev libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

# --- Build COLMAP (CPU-only, no GUI, no CUDA) ---
ARG COLMAP_TAG=3.8
RUN git clone --depth 1 --branch ${COLMAP_TAG} https://github.com/colmap/colmap.git /tmp/colmap

RUN cmake -S /tmp/colmap -B /tmp/colmap/build -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/colmap \
    -DGUI_ENABLED=OFF \
    -DCUDA_ENABLED=OFF \
    -DTESTS_ENABLED=OFF

RUN cmake --build /tmp/colmap/build --target install --parallel 1

# --- Build OpenMVS ---
ARG OPENMVS_TAG=v2.3.0
RUN git clone --depth 1 --branch ${OPENMVS_TAG} https://github.com/cdcseacave/openMVS.git /tmp/openmvs

RUN cmake -S /tmp/openmvs -B /tmp/openmvs/build -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/opt/openmvs

RUN cmake --build /tmp/openmvs/build --target install --parallel 1

# ---------- Stage 2: Runtime ----------
FROM ubuntu:22.04 AS runtime
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates bash \
    python3 python3-venv python3-pip \
    libboost-filesystem1.74.0 libboost-graph1.74.0 libboost-program-options1.74.0 libboost-system1.74.0 \
    libceres2 libgflags2.2 libgoogle-glog0v5 \
    libfreeimage3 libglew2.2 \
    libsqlite3-0 \
    libopencv-core4.5d libopencv-imgproc4.5d libopencv-imgcodecs4.5d \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    libtbb2 \
    libgl1-mesa-glx libglu1-mesa \
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
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x /app/worker/pipeline.sh

RUN colmap -h >/dev/null 2>&1
RUN InterfaceCOLMAP -h >/dev/null 2>&1

CMD ["python", "-u", "worker/main.py"]
