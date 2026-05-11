FROM python:3.12-slim

# System deps for WeasyPrint + fonts
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpango-1.0-0 libpangocairo-1.0-0 libgdk-pixbuf-2.0-0 \
    libffi-dev libcairo2 libglib2.0-0 fonts-dejavu-core \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Install dependencies
COPY pyproject.toml .
COPY src/ src/
RUN pip install --no-cache-dir .

# Copy application code
COPY alembic.ini alembic.ini
COPY migrations/ migrations/

EXPOSE 8000

# Run migrations + start server
CMD ["sh", "-c", "alembic upgrade head 2>/dev/null; uvicorn audit_engine.api.app:app --host 0.0.0.0 --port 8000"]
