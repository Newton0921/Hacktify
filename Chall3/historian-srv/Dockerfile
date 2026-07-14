FROM python:3.11-slim

RUN pip install --no-cache-dir asyncua

COPY historian_server.py /opt/historian/historian_server.py

EXPOSE 4840

CMD ["python3", "-u", "/opt/historian/historian_server.py"]
