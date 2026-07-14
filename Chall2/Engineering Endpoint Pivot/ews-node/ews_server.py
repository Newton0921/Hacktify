import asyncio
import os
import sys
import datetime
import logging
from asyncua import Server

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("ews_server")

async def main():
    server = Server()
    await server.init()

    # Get EWS_IP and ENGSTATION_ID from environment
    ews_ip = os.environ.get("EWS_IP")
    engstation_id = os.environ.get("ENGSTATION_ID")

    if not ews_ip:
        logger.error("EWS_IP environment variable not set. Exiting.")
        sys.exit(1)
    if not engstation_id:
        logger.error("ENGSTATION_ID environment variable not set. Exiting.")
        sys.exit(1)

    endpoint = f"opc.tcp://{ews_ip}:4840/freeopcua/server/"
    server.set_endpoint(endpoint)
    server.set_server_name("Prabal Urja Engineering Workstation")

    # Set server properties directly to override default values
    server.product_uri = engstation_id
    await server.set_application_uri(engstation_id)

    # Set build info with product_uri as ENGSTATION_ID
    logger.info(f"Setting BuildInfo ProductUri to: {engstation_id}")
    await server.set_build_info(
        product_uri=engstation_id,
        manufacturer_name="Prabal Urja Pvt Ltd",
        product_name="EWS Control Station",
        software_version="v2.4.12",
        build_number="2026-07-01",
        build_date=datetime.datetime.now()
    )

    # Explicitly write value to the standard ProductUri node (ns=0;i=2262)
    product_uri_node = server.get_node("ns=0;i=2262")
    await product_uri_node.write_value(engstation_id)

    logger.info(f"Starting OPC UA Server on {endpoint}")
    async with server:
        while True:
            await asyncio.sleep(1)

if __name__ == "__main__":
    asyncio.run(main())
