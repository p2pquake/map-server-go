# 地図生成サーバーのコンテナイメージ (Cloud Run 向け)
#   docker build -t map-server-go .
#   docker run --rm -p 8080:8080 map-server-go

FROM golang:1.27.3 AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
COPY mapdraw/ ./mapdraw/
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /mapserver .

FROM gcr.io/distroless/static-debian13:nonroot
COPY --from=build /mapserver /app/mapserver
# 実行ファイルと同じ場所の resources を自動で使います (ライセンス表記のファイルも同梱します)
COPY resources/ /app/resources/
# Cloud Run は環境変数 PORT を上書きします。ローカルで docker run したときの既定値です
ENV PORT=8080
EXPOSE 8080
ENTRYPOINT ["/app/mapserver"]
