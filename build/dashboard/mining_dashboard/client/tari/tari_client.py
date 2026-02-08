import aiohttp
import logging
import re
import grpc
import os

from config.config import TARI_GRPC_ADDRESS, TARI_EXPLORER_URL

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
        self.explorer_url = TARI_EXPLORER_URL
        self._channel = None
        self._stub = None

    def _ensure_channel(self):
        if self._channel is None:
            self._channel = grpc.aio.insecure_channel(self.grpc_address)
            self._stub = base_node_pb2_grpc.BaseNodeStub(self._channel)
        return self._stub

    async def get_network_height(self):
        """Scrapes the official Tari Block Explorer for the current network height."""
        try:
            async with self.session.get(self.explorer_url, timeout=5) as response:
                if response.status == 200:
                    html = await response.text()
                    # Look for the Block Height value preceding the label
                    # HTML structure: <p ...>197,519</p><p ...>Block<br>Height</p>
                    match = re.search(r'>([\d,]+)</p>\s*<p[^>]*>Block<br>Height</p>', html)
                    if match:
                        return int(match.group(1).replace(',', ''))
        except Exception as e:
            logger.error(f"Failed to scrape Tari explorer: {e}")
        return 0

    async def get_local_height(self):
        """Fetches the local node's tip height via gRPC."""
        try:
            stub = self._ensure_channel()
            request = empty_pb2.Empty()
            response = await stub.GetTipInfo(request, timeout=5)
            
            if response and response.metadata:
                return response.metadata.best_block_height
        except Exception as e:
            logger.error(f"Tari gRPC Error: {e}")
            # Reset channel to force reconnection on next attempt
            if self._channel:
                await self._channel.close()
                self._channel = None
                self._stub = None
        return None

    async def get_sync_status(self):
        """
        Aggregates local and network stats to determine sync progress.
        Returns a dict compatible with the dashboard sync view.
        """
        network_height = await self.get_network_height()
        local_height = await self.get_local_height()
        
        # If we can't get network height OR local height (error/no protos), assume not syncing
        # This prevents the dashboard from locking up if the Tari node is down or unconfigured
        if network_height == 0 or local_height is None:
            return {"is_syncing": False}

        # If local is significantly behind network (e.g. > 3 blocks), we are syncing
        is_syncing = local_height < (network_height - 3)
        
        percent = 0
        if network_height > 0:
            percent = int((local_height / network_height) * 100)

        return {
            "is_syncing": is_syncing,
            "current": local_height,
            "target": network_height,
            "percent": percent
        }

    async def close(self):
        if self._channel:
            await self._channel.close()
            self._channel = None