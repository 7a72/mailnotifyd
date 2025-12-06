FROM alpine:latest

ARG TARGETARCH

RUN apk add --no-cache ca-certificates tzdata

COPY dist/${TARGETARCH}/email_notifier /email_notifier

ENV BIND_ADDR=:8000
EXPOSE 8000

ENTRYPOINT ["/email_notifier"]
