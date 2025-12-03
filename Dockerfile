FROM golang:1.25-alpine AS builder

WORKDIR /app

RUN apk add --no-cache ca-certificates tzdata

COPY go.mod go.sum ./
RUN go mod download

COPY . .

RUN CGO_ENABLED=0 GOOS=linux go build -o email-notifier ./...

FROM alpine:3.20

RUN adduser -D -H app \
    && apk add --no-cache ca-certificates tzdata

WORKDIR /app

COPY --from=builder /app/email-notifier /app/email-notifier

ENV BIND_ADDR=:8000

EXPOSE 8000

USER app

ENTRYPOINT ["./email-notifier"]
