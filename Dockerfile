# Dockerfile — IT-Stack TAIGA wrapper
# Module 15 | Category: it-management | Phase: 4
# Base image: taigaio/taiga-front:latest

FROM taigaio/taiga-front:latest

# Labels
LABEL org.opencontainers.image.title="it-stack-taiga" \
      org.opencontainers.image.description="Taiga agile project management" \
      org.opencontainers.image.vendor="it-stack-dev" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.source="https://github.com/it-stack-dev/it-stack-taiga"

# Copy custom configuration and scripts
COPY src/ /opt/it-stack/taiga/
COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 \
    CMD curl -f http://localhost/health || exit 1

ENTRYPOINT ["/entrypoint.sh"]
