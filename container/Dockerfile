FROM nousresearch/hermes-agent:v2026.9.24

# Install Azure Blob Storage SDK into Hermes virtual environment
RUN uv pip install --python /opt/hermes/.venv/bin/python azure-storage-blob

# Copy the Azure persistence scripts.
COPY scripts/ /opt/hermes-azure/scripts/
COPY services/ /opt/hermes-azure/services/

RUN chmod 0755 /opt/hermes-azure/scripts/*.sh \
    && chmod 0755 /opt/hermes-azure/services/*.sh

# Run persistence initialization through the original Hermes entrypoint.
CMD ["/opt/hermes-azure/services/start-hermes.sh"]