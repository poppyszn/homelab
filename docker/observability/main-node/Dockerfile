FROM telegraf:latest

# Install Speedtest CLI
RUN apt-get update && apt-get install -y curl gnupg \
    && curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash \
    && apt-get install -y speedtest-cli \
    && rm -rf /var/lib/apt/lists/*

ENTRYPOINT ["telegraf"]