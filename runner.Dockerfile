FROM myoung34/github-runner:latest

ARG NODE_VERSION=22.23.2
ARG NODE_SHA256_X64=d60acfe00a2932254bb0ad20e01b0d74397a0875595de719654b214f4b03f307
ARG NODE_SHA256_ARM64=fff4078c5def658577f92c88db7db3bc0072924bfb93fe52c1e744a54e94abb8

RUN apt-get update \
    && apt-get purge -y nodejs libnode64 \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

RUN ARCH="$(dpkg --print-architecture)" \
    && case "${ARCH}" in \
        amd64) NODE_ARCH=x64; NODE_SHA256="${NODE_SHA256_X64}" ;; \
        arm64) NODE_ARCH=arm64; NODE_SHA256="${NODE_SHA256_ARM64}" ;; \
        *) echo "unsupported architecture: ${ARCH} (supported: amd64, arm64)" >&2; exit 1 ;; \
    esac \
    && curl -fsSLo /tmp/node.tar.xz \
        --connect-timeout 30 --speed-limit 1024 --speed-time 30 --max-time 300 \
        --retry 5 --retry-delay 5 --retry-connrefused \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODE_ARCH}.tar.xz" \
    && echo "${NODE_SHA256}  /tmp/node.tar.xz" | sha256sum -c - \
    && mkdir -p /usr/local/lib/nodejs \
    && tar -xJf /tmp/node.tar.xz -C /usr/local/lib/nodejs \
    && rm /tmp/node.tar.xz \
    && ln -sf /usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/node /usr/local/bin/node \
    && ln -sf /usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/npm /usr/local/bin/npm \
    && ln -sf /usr/local/lib/nodejs/node-v${NODE_VERSION}-linux-${NODE_ARCH}/bin/npx /usr/local/bin/npx
