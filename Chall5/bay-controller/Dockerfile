FROM alpine:latest
RUN apk add --no-cache python3 bash iproute2 openssl
COPY entrypoint.sh /entrypoint.sh
COPY automation_service.py /app/automation_service.py
COPY l2_responder.py /app/l2_responder.py
COPY scil_validator.py /app/scil_validator.py
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
