FROM python:3.12-slim
WORKDIR /app
COPY rmp_server.py .
ENV RMP_DATA=/data RMP_PORT=8765
VOLUME /data
EXPOSE 8765
CMD ["python3", "rmp_server.py", "--host", "0.0.0.0"]
