import sys
import json
import asyncio
import websockets

ws_url = sys.argv[1]

async def dump():
    async with websockets.connect(ws_url) as websocket:
        payload = {
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {
                "expression": "document.body.innerHTML",
                "returnByValue": True
            }
        }
        await websocket.send(json.dumps(payload))
        response = await websocket.recv()
        data = json.loads(response)
        html = data.get("result", {}).get("result", {}).get("value", "")
        print(html[:4000]) # first 4000 chars

asyncio.run(dump())
