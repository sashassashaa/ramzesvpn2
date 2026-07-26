import aiohttp, logging
from datetime import datetime, timedelta, timezone
from typing import Optional, Tuple

logger = logging.getLogger(__name__)

class RemnaWaveClient:
    def __init__(self, api_url: str, api_token: str):
        self.api_url = api_url.rstrip('/')
        self.headers = {"Authorization": f"Bearer {api_token}", "Content-Type": "application/json"}

    async def health_check(self) -> bool:
        try:
            async with aiohttp.ClientSession(headers=self.headers) as s:
                async with s.get(f"{self.api_url}/api/health", timeout=5, ssl=False) as r:
                    return r.status in (200, 401, 302, 404)
        except:
            return False

    async def create_user(self, username: str, expire_days: int) -> Tuple[Optional[str], str]:
        expire_at = (datetime.now(timezone.utc) + timedelta(days=expire_days)).strftime("%Y-%m-%dT%H:%M:%S.000Z")
        payload = {"username": username, "status": "ACTIVE", "expireAt": expire_at, "dataLimit": 0, "trafficLimitStrategy": "NO_RESET"}
        
        async with aiohttp.ClientSession(headers=self.headers) as s:
            try:
                async with s.post(f"{self.api_url}/api/users", json=payload, timeout=15, ssl=False) as r:
                    if r.status in (200, 201):
                        data = await r.json()
                        return data.get("response", data).get("subscriptionUrl", ""), ""
                    return None, f"Ошибка {r.status}"
            except Exception as e:
                return None, str(e)[:100]
