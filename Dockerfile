# ---- Stage 1: OpenMVS donor ----
FROM openmvs/openmvs-ubuntu:latest AS openmvs

# ---- Stage 2: COLMAP donor (CPU-only) ----
FROM graffitytech/colmap:3.8-cpu-ubuntu22.04 AS colmap

# ---- Stage 3: Final runtime (stable Python) ----
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime deps + Python (this is where we run the worker)
RUN apt-get update && apt-get install -y \
    ca-certificates bash \
    python3-full python3-venv python3-pip \
    locales \
    \
    # Common runtime libs needed by COLMAP/OpenMVS binaries (Ubuntu 22.04)
    libceres2 libgoogle-glog0v5 libgflags2.2 \
    libfreeimage3 \
    libopencv-core4.5 libopencv-imgcodecs4.5 libopencv-imgproc4.5 \
    libqt5core5a libqt5gui5 libqt5widgets5 libqt5opengl5 \
    libglew2.2 libglfw3 \
    \
    && rm -rf /var/lib/apt/lists/*

# Ensure UTF-8 locale
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# Copy COLMAP binaries and libs into /opt
COPY --from=colmap /usr/local/ /opt/colmap/

# Copy OpenMVS binaries and libs into /opt
COPY --from=openmvs /usr/bin/ /opt/openmvs/usr_bin/
COPY --from=openmvs /usr/local/bin/ /opt/openmvs/usr_local_bin/
COPY --from=openmvs /usr/local/lib/ /opt/openmvs/usr_local_lib/

# Put tools on PATH and libs on LD_LIBRARY_PATH
ENV PATH="/opt/colmap/bin:/opt/openmvs/usr_bin:/opt/openmvs/usr_local_bin:${PATH}"
ENV LD_LIBRARY_PATH="/opt/colmap/lib:/opt/openmvs/usr_local_lib:${LD_LIBRARY_PATH}"

# Sanity check: fail build if python stdlib is broken
RUN python3 -c "import site; import sys; print('python ok', sys.version)"

# Python venv
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:${PATH}"

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python", "-u", "worker/main.py"]
