"""aistack-mcp-web — two web tools behind one MCP (Streamable HTTP) endpoint.

  web_search(query, limit)  -> SearXNG
  fetch_page(url)           -> Crawl4AI /md (markdown of one page)

WHY A WRAPPER INSTEAD OF EXPOSING SearXNG AND Crawl4AI DIRECTLY (NOM-413).
Crawl4AI's own HTTP API includes /execute_js, /screenshot and /pdf.  An agent
that can reach those can run arbitrary script in a browser.  This server is the
ONLY caller of both back ends, and it exposes exactly two tools with exactly
the arguments the LiteLLM allowlist lists (config/mcp/allowlist.yaml).

fetch_page REFUSES private targets: it resolves the host and rejects loopback,
RFC1918, link-local (incl. cloud metadata 169.254.169.254), CGNAT and
unspecified addresses, and non-http(s) schemes.  This is a first line only: the
browser resolves the name again, so a rebinding host can still win a race.  The
host-firewall rules of Tier B are the second line and are not part of this image.

Stdio is not offered.  The only transport is Streamable HTTP.
"""
import ipaddress
import logging
import os
import socket
from urllib.parse import urlparse

import httpx
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

SEARXNG = os.environ.get("SEARXNG_URL", "http://searxng:8080")
CRAWL4AI = os.environ.get("CRAWL4AI_URL", "http://crawl4ai:11235")
MAX_CHARS = int(os.environ.get("MAX_PAGE_CHARS", "20000"))
HOSTS = [h for h in os.environ.get("MCP_ALLOWED_HOSTS", "mcp-web:8900,mcp-web").split(",") if h]

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("aistack-mcp-web")

mcp = FastMCP(
    "web",
    host="0.0.0.0",
    port=8900,
    stateless_http=True,
    json_response=True,
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True, allowed_hosts=HOSTS),
)


def _refuse_private(url: str) -> str:
    u = urlparse(url)
    if u.scheme not in ("http", "https") or not u.hostname:
        raise ValueError("only http(s) URLs with a host are allowed")
    try:
        infos = socket.getaddrinfo(u.hostname, u.port or (443 if u.scheme == "https" else 80),
                                   type=socket.SOCK_STREAM)
    except socket.gaierror as e:
        raise ValueError(f"cannot resolve {u.hostname}: {e}")
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_unspecified
                or ip.is_multicast or ip.is_reserved
                or ip in ipaddress.ip_network("100.64.0.0/10")):
            raise ValueError(f"{u.hostname} resolves to a non-public address ({ip}); refused")
    return url


@mcp.tool()
async def web_search(query: str, limit: int = 5) -> dict:
    """Search the web (SearXNG). Returns title, url and a snippet for each hit."""
    limit = max(1, min(int(limit), 10))
    async with httpx.AsyncClient(timeout=30) as c:
        r = await c.get(f"{SEARXNG}/search", params={"q": query, "format": "json"})
        r.raise_for_status()
    hits = r.json().get("results", [])[:limit]
    return {"query": query, "results": [
        {"title": h.get("title"), "url": h.get("url"), "snippet": h.get("content")} for h in hits]}


@mcp.tool()
async def fetch_page(url: str) -> dict:
    """Fetch one public web page and return it as markdown (Crawl4AI). Private addresses are refused."""
    _refuse_private(url)
    async with httpx.AsyncClient(timeout=90) as c:
        r = await c.post(f"{CRAWL4AI}/md", json={"url": url, "f": "fit", "q": None, "c": "0"})
        r.raise_for_status()
    body = r.json()
    md = body.get("markdown") or ""
    return {"url": url, "success": bool(body.get("success", True)),
            "markdown": md[:MAX_CHARS], "truncated": len(md) > MAX_CHARS}


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
