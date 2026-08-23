FROM python:3.12-alpine
RUN apk add --no-cache wget \
  && adduser -D -u 1000 app
WORKDIR /app
COPY server.py .
RUN mkdir -p /data /config && chown -R app:app /data /config /app
USER 1000
EXPOSE 8080
CMD ["python3", "server.py"]
