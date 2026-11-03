FROM mcr.microsoft.com/dotnet/sdk:10.0.403

ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=1 \
    DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 \
    DOTNET_CLI_HOME=/tmp/dotnet-home \
    NUGET_PACKAGES=/tmp/nuget-packages \
    HOME=/tmp/build-home

WORKDIR /workspace
COPY . .

# Compilation deliberately runs in the container entrypoint, not an image layer.
# Each invocation therefore measures a fresh restore and build, even when Docker
# can reuse the entire image. Writable sources support a Linux host's own UID.
RUN test "$(dotnet --version)" = "10.0.403" \
    && command -v pwsh \
    && mkdir -p "$DOTNET_CLI_HOME" "$NUGET_PACKAGES" "$HOME" \
    && chmod -R a+rwX /workspace "$DOTNET_CLI_HOME" "$NUGET_PACKAGES" "$HOME"

ENTRYPOINT ["/bin/bash", "/workspace/scripts/build-in-container.sh"]
