# Worker container image that runs generation and Verilator validation.
FROM python:3.11-slim

# Application working directory inside the container.
WORKDIR /app

# Install toolchain needed to compile and run Verilator benchmarks.
RUN apt-get update && apt-get install -y \
    verilator \
    g++ \
    make \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Install worker Python dependencies.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy worker logic.
COPY worker.py .

# Shared volume mount points for job artifacts and metadata.
RUN mkdir -p /app/jobs /app/data

# Start the long-running queue consumer.
CMD ["python", "worker.py"]
