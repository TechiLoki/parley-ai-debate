FROM python:3.12-slim
WORKDIR /app
COPY . .
RUN useradd --uid 10001 --create-home app
USER app
EXPOSE 8000
CMD ["python", "app.py"]
