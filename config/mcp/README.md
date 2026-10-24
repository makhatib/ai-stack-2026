The MCP allowlist lives in `config/litellm/config.yaml` (`mcp_servers:`) — one place.
`config/mcp/tools.lock.json` is the committed copy of each tool's name and argument keys
(wire name `<server>-<tool>`), which `scripts/mcp-verify.py` compares with what the
backends advertise and with the allowlist.
