FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    blender \
    python3 \
    python3-pip \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

COPY docker/blender-worker/requirements.txt /workspace/requirements.txt
RUN pip3 install --break-system-packages -r /workspace/requirements.txt

COPY scripts /workspace/scripts
COPY prompts /workspace/prompts
COPY blender /workspace/blender

CMD ["python3", "/workspace/scripts/run_factory.py"]
