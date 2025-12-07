FROM alpine:latest

ARG TARGETARCH

RUN apk add --no-cache ca-certificates tzdata

COPY dist/${TARGETARCH}/mailnotifyd /mailnotifyd

ENV BIND_ADDR=:8000
EXPOSE 8000

ENTRYPOINT ["/mailnotifyd"]
