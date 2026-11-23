FROM golang:1.27.4-alpine3.24

WORKDIR /src
COPY go.mod ./
COPY . ./
RUN CGO_ENABLED=0 go test ./... \
 && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /usr/local/bin/hello-auth .

USER nobody
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/hello-auth"]
