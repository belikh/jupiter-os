import sys
import json
import asyncio
import websockets

ws_url = sys.argv[1]
username = sys.argv[2]
password = sys.argv[3]

async def login():
    async with websockets.connect(ws_url) as websocket:
        js_code = f"""
        (function() {{
            function findElementDeep(selector, root = document) {{
                let found = null;
                const traverser = (node) => {{
                    if (!node) return;
                    if (node.nodeType === Node.ELEMENT_NODE && node.matches(selector)) {{
                        found = node;
                        return;
                    }}
                    if (node.shadowRoot) {{
                        traverser(node.shadowRoot);
                    }}
                    if (found) return;
                    
                    const children = node.childNodes || [];
                    for (const child of children) {{
                        traverser(child);
                        if (found) return;
                    }}
                }};
                traverser(root);
                return found;
            }}

            const userField = findElementDeep('ha-input[type="text"]');
            const passField = findElementDeep('ha-input[type="password"]');
            const keepLoggedBtn = findElementDeep('ha-checkbox');
            const loginBtn = findElementDeep('.action ha-button');

            if (!userField || !passField) {{
                return "inputs_not_found: user=" + !!userField + ", pass=" + !!passField;
            }}

            // Enter username
            userField.value = "{username}";
            userField.dispatchEvent(new Event('input', {{ bubbles: true, composed: true }}));
            userField.dispatchEvent(new Event('change', {{ bubbles: true, composed: true }}));

            // Enter password
            passField.value = "{password}";
            passField.dispatchEvent(new Event('input', {{ bubbles: true, composed: true }}));
            passField.dispatchEvent(new Event('change', {{ bubbles: true, composed: true }}));

            // Check "Keep me logged in"
            if (keepLoggedBtn && !keepLoggedBtn.checked) {{
                keepLoggedBtn.checked = true;
                keepLoggedBtn.dispatchEvent(new Event('change', {{ bubbles: true, composed: true }}));
            }}

            // Wait a moment for events to settle, then click submit
            setTimeout(() => {{
                if (loginBtn) {{
                    loginBtn.click();
                }}
            }}, 200);

            return "filled_and_submitted";
        }})()
        """

        payload = {
            "id": 1,
            "method": "Runtime.evaluate",
            "params": {
                "expression": js_code,
                "returnByValue": True
            }
        }
        await websocket.send(json.dumps(payload))
        response = await websocket.recv()
        print(response)

asyncio.run(login())
