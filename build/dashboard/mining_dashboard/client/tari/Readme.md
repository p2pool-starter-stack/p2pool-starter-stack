# Tari gRPC Collector

## Generate Protobuf Files
Ensure `base_node.proto` and `types.proto` are in the `proto/` subdirectory, then run:

```bash
docker run --rm -v "$PWD":/work -w /work python:3.11-slim \
  /bin/bash -c "pip install grpcio-tools && python -m grpc_tools.protoc -Iproto --python_out=generated --grpc_python_out=generated proto/*.proto && sed -i 's/^import.*_pb2/from . \0/' generated/*_pb2*.py"
```