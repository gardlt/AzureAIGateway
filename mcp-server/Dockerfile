FROM golang:1.23-alpine AS build
WORKDIR /src
COPY go.mod .
COPY main.go .
RUN CGO_ENABLED=0 GOOS=linux go build -o /mcp-server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /mcp-server /mcp-server
EXPOSE 3000
ENTRYPOINT ["/mcp-server"]
