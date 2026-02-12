FROM colmap/colmap:latest

# Install python + pip (image is ubuntu-based)
RUN apt-get update && apt-get install -y python3 python3-pip && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt .
RUN pip3 install --no-cache-dir -r requirements.txt

COPY worker ./worker
RUN chmod +x worker/pipeline.sh

CMD ["python3", "-u", "worker/main.py"]
