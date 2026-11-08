FROM ghcr.io/anomalyco/opencode:2.2.6

RUN sed -i 's/^#\(.*community\)/\1/' /etc/apk/repositories && \
    apk update && \
    apk add --no-cache \
    binutils-arm-none-eabi gcc-arm-none-eabi newlib-arm-none-eabi picolibc-arm-none-eabi \
    build-base catch2 cmake \
    bash \
    curl \
    file \
    git \
    jq \
    nodejs npm \
    py3-numpy py3-pillow py3-pip py3-pyserial \
    python3 \
    ripgrep \
    wget

WORKDIR /workspace

COPY --chown=1000:1000 --parents .config .

RUN adduser -D -u 1000 -g 1000 -h /workspace user

USER user

COPY --chown=1000:1000 --chmod=0555 setup.sh ep.sh .
RUN ./setup.sh

ENV OPENCODE_DISABLE_MODELS_FETCH=1
ENV OPENCODE_DISABLE_FREE_MODELS=1
