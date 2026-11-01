# swe-flow backend

本目录是工作台内置的 Go 服务源码，由仓库根目录的 `build.sh` 构建为
`Resources/bin/swe-flow`。它负责：

- 本机 HTTP API（默认 `127.0.0.1:8765`）；
- 平台预检、提交计划、证据和回执；
- 本机私有凭据读取、请求校验和任务状态机。

## 构建

从仓库根目录：

```bash
./build.sh --no-dmg
```

或单独构建：

```bash
go build -trimpath -o .build/swe-flow ./cmd/swe-flow
```

## 测试

```bash
go test ./...
```

## 边界

- 服务只绑定回环地址；
- 非 GET 请求校验同源 Origin 和 CSRF；
- 平台凭据只从本机私有配置或环境变量读取，不写入日志/响应；
- 工作台不是多租户服务器，不要暴露到公网。
