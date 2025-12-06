FROM alpine:latest AS builder

WORKDIR /app

RUN apk add --no-cache zig ca-certificates tzdata

COPY build.zig build.zig.zon ./
COPY src ./src

RUN zig build -Doptimize=ReleaseFast

FROM alpine:latest

RUN adduser -D -H app \
    && apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/zig-out/bin/email_notifier /app/email_notifier

ENV BIND_ADDR=:8000

EXPOSE 8000

USER app

ENTRYPOINT ["./email_notifier"]
