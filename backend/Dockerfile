# Backend API container image for HDLFACTORY.
FROM python:3.11-slim

# Application working directory inside the container.
WORKDIR /app

# Install Python dependencies first for better layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy app code and provision runtime storage directories.
COPY app.py .
RUN mkdir -p /app/jobs /app/data

EXPOSE 8000

# Start FastAPI via Uvicorn.
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
