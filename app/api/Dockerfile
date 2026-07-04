FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o todo-api .

FROM alpine:3.21
COPY --from=builder /app/todo-api /usr/local/bin/
EXPOSE 8080
CMD ["todo-api"]
