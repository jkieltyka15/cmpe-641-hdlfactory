# Utility container image with Verilator toolchain for manual experiments.
FROM ubuntu:24.04

# Install Verilator and minimal build dependencies.
RUN apt-get update && apt-get install -y \
    verilator \
    g++ \
    make \
    bash \
    && rm -rf /var/lib/apt/lists/*

# Default workspace for mounting HDL sources.
WORKDIR /workspace

# Launch an interactive shell by default.
CMD ["bash"]
