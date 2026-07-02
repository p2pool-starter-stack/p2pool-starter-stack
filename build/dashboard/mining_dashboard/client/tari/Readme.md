# Tari gRPC Collector

The Tari gRPC client and its generated protobuf stubs.

## Generate Protobuf Files

Ensure `base_node.proto` and `types.proto` are in the `proto/` subdirectory, then run:

```bash
docker run --rm -v "$PWD":/work -w /work ghcr.io/astral-sh/uv:0.10.10-python3.11-trixie-slim \
  /bin/bash -c "uvx --from grpcio-tools python -m grpc_tools.protoc -Iproto --python_out=generated --grpc_python_out=generated proto/*.proto && sed -i 's/^import.*_pb2/from . \0/' generated/*_pb2*.py"
```
