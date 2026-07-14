FROM python:3.11-slim

# Install system build dependencies for compiling pybind11 c104 module
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    g++ \
    cmake \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install c104 library
RUN pip install --no-cache-dir c104

# Setup working directory
WORKDIR /opt/rtu

# Copy server code
COPY rtu_server.py .

# Run the server
CMD ["python3", "rtu_server.py"]
