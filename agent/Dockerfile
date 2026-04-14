FROM python:3.12-slim

WORKDIR /app

RUN apt-get update -qq && apt-get install -y -qq curl && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

EXPOSE 8042

# Default: run agent loop. Override with "api" to run the API server.
CMD ["python", "main.py"]
