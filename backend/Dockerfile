FROM python:3.12-slim AS base
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .

FROM base AS test
COPY tests/ /app/tests/
RUN python -m unittest discover -s tests -v

FROM base AS runtime
RUN useradd --uid 10001 --create-home appuser
USER appuser
EXPOSE 5000
CMD ["gunicorn", "--workers", "1", "--bind", "0.0.0.0:5000", "app:app"]
