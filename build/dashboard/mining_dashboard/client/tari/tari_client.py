import aiohttp
import logging
import grpc
import os

from config.config import TARI_GRPC_ADDRESS

logger = logging.getLogger("TariClient")

# Attempt to import generated protobuf modules
# See Readme.md for generation instructions (requires grpcio-tools)
from .generated import base_node_pb2
from .generated import base_node_pb2_grpc
from google.protobuf import empty_pb2

class TariClient:
    def __init__(self, session: aiohttp.ClientSession):
        self.session = session
        self.grpc_address = TARI_GRPC_ADDRESS
        self._channel = None
        self._stub = None

    def _ensure_channel(self):
        if self._channel is None:
            self._channel = grpc.aio.insecure_channel(self.grpc_address)
            self._stub = base_node_pb2_grpc.BaseNodeStub(self._channel)
        return self._stub

    async def _reset_channel(self):
        """Drop the gRPC channel so the next call reconnects (used after errors)."""
        if self._channel:
            await self._channel.close()
        self._channel = None
        self._stub = None

    async def get_sync_status(self):
        """
        Determine Tari sync progress from the node's OWN gRPC, not the external block
        explorer. `initial_sync_achieved` is the authoritative "fully synced" flag; while
        syncing, GetSyncProgress.tip_height is the height the node is working toward.

        This replaces the old explorer-based logic, whose failure mode was: a transient
        explorer outage returned network height 0, the code assumed "synced at local
        height", and the dashboard flashed a premature 100% ✔ before dropping back to a
        percentage. The node always knows its own state, so there's nothing external to fail.
        """
        try:
            stub = self._ensure_channel()
            tip = await stub.GetTipInfo(empty_pb2.Empty(), timeout=5)
        except Exception as e:
            logger.error(f"Tari gRPC GetTipInfo error: {e}")
            await self._reset_channel()
            return {"is_syncing": False}

        local_height = tip.metadata.best_block_height

        # The node reports initial sync complete — trust it over any height heuristic.
        if tip.initial_sync_achieved:
            return {"is_syncing": False, "current": local_height,
                    "target": local_height, "percent": 100}

        # Still syncing: ask the node what height it is syncing toward.
        target = 0
        try:
            progress = await stub.GetSyncProgress(empty_pb2.Empty(), timeout=5)
            if progress.local_height:
                local_height = progress.local_height
            target = progress.tip_height
        except Exception as e:
            logger.error(f"Tari gRPC GetSyncProgress error: {e}")
            await self._reset_channel()

        # No reliable target yet (early startup / between sync rounds): report syncing
        # without a false 100%, so the UI shows a loading state, not a premature ✔.
        if target <= local_height:
            return {"is_syncing": True, "current": local_height, "target": 0, "percent": 0}

        percent = int((local_height / target) * 100)
        return {"is_syncing": True, "current": local_height, "target": target, "percent": percent}

    async def close(self):
        if self._channel:
            await self._channel.close()
            self._channel = None