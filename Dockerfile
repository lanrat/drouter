FROM docker:29.0.1-cli-alpine3.22

ENV LOG_LEVEL=INFO
ENV DEFAULT_ROUTE_DELAY=0
ENV RETRY_ATTEMPTS=3
ENV RETRY_DELAY=1

COPY drouter.sh /usr/local/bin/drouter.sh

RUN set -eux; \
    apk add --no-cache jq bash && \
    chmod +x /usr/local/bin/drouter.sh && \
    rm -rf /tmp/* /var/tmp/* /var/log/* /var/cache/apk/*

ENTRYPOINT ["/usr/local/bin/drouter.sh"]
