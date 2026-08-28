"""Read-only Wealth position-lot client protected by Cloudflare Access."""

from __future__ import annotations

import asyncio
import hashlib
import json
from collections.abc import Iterable
from datetime import date
from decimal import Decimal, InvalidOperation
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from .models import (
    PositionCostSlot,
    WealthAccessCredentials,
    WealthLotsStatus,
    utc_now,
)

LOTS_PATH = "/api/positions/lots"
MAX_RESPONSE_BYTES = 2 * 1024 * 1024


class WealthLotsError(RuntimeError):
    pass


class WealthAccessError(WealthLotsError):
    pass


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        raise WealthAccessError("Wealth API redirect was rejected")


def _decimal(value: Any) -> Decimal | None:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, ValueError, TypeError):
        return None
    return result if result.is_finite() else None


def _origin(base_url: str) -> tuple[str, str]:
    parsed = urlsplit(base_url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or parsed.port not in {None, 443}
    ):
        raise ValueError("Wealth URL must be an HTTPS origin without a path")
    host = parsed.hostname.lower()
    return urlunsplit(("https", host, "", "", "")), host


class WealthLotsProvider:
    def __init__(self) -> None:
        self._credentials: WealthAccessCredentials | None = None
        self._lots_by_con_id: dict[int, tuple[PositionCostSlot, ...]] = {}
        self._report_date: date | None = None
        self._status = WealthLotsStatus()

    def status(self) -> WealthLotsStatus:
        return self._status

    async def configure(self, credentials: WealthAccessCredentials) -> WealthLotsStatus:
        self._credentials = credentials
        return await self.refresh()

    async def clear(self) -> WealthLotsStatus:
        self._credentials = None
        self._lots_by_con_id = {}
        self._report_date = None
        self._status = WealthLotsStatus()
        return self._status

    async def refresh(self) -> WealthLotsStatus:
        credentials = self._credentials
        if credentials is None:
            return self._status
        try:
            payload = await asyncio.to_thread(self._fetch, credentials)
            lots_by_con_id, report_date = self._parse(payload)
        except WealthLotsError as exc:
            self._lots_by_con_id = {}
            self._report_date = None
            self._status = WealthLotsStatus(
                configured=True,
                active=False,
                error=str(exc),
            )
            return self._status

        self._lots_by_con_id = lots_by_con_id
        self._report_date = report_date
        self._status = WealthLotsStatus(
            configured=True,
            active=True,
            report_date=report_date,
            lot_count=sum(len(items) for items in lots_by_con_id.values()),
            last_update_at=utc_now(),
        )
        return self._status

    def slots_for_position(
        self, con_id: int, position_quantity: Decimal
    ) -> tuple[PositionCostSlot, ...]:
        lots = self._lots_by_con_id.get(con_id, ())
        if not lots or position_quantity == 0:
            return ()
        lot_quantity = sum((slot.quantity for slot in lots), Decimal(0))
        expected = abs(position_quantity)
        tolerance = max(Decimal("0.00000001"), expected * Decimal("0.00000001"))
        if abs(lot_quantity - expected) > tolerance:
            return ()
        return lots

    @staticmethod
    def _fetch(credentials: WealthAccessCredentials) -> bytes:
        origin, expected_host = _origin(credentials.base_url)
        url = f"{origin}{LOTS_PATH}"
        request = Request(
            url,
            headers={
                "Accept": "application/json",
                "CF-Access-Client-Id": credentials.client_id,
                "CF-Access-Client-Secret": credentials.client_secret,
                "User-Agent": "OpenIBKR-Helper/0.2",
            },
            method="GET",
        )
        if urlsplit(request.full_url).hostname != expected_host:
            raise WealthLotsError("Wealth API origin invariant failed")
        try:
            with build_opener(_RejectRedirects()).open(request, timeout=12) as response:
                content_type = response.headers.get_content_type()
                if content_type != "application/json":
                    raise WealthLotsError("Wealth API returned a non-JSON response")
                payload = response.read(MAX_RESPONSE_BYTES + 1)
                if len(payload) > MAX_RESPONSE_BYTES:
                    raise WealthLotsError("Wealth API response exceeded the size limit")
                return payload
        except HTTPError as exc:
            if exc.code in {401, 403}:
                raise WealthAccessError("Cloudflare Access credentials were rejected") from exc
            raise WealthLotsError("Wealth API returned an error") from exc
        except WealthLotsError:
            raise
        except (URLError, TimeoutError, OSError) as exc:
            raise WealthLotsError("Wealth API is unreachable") from exc

    @staticmethod
    def _parse(payload: bytes) -> tuple[dict[int, tuple[PositionCostSlot, ...]], date | None]:
        try:
            decoded = json.loads(payload)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise WealthLotsError("Wealth API response was invalid") from exc
        if not isinstance(decoded, list):
            raise WealthLotsError("Wealth API response was invalid")

        grouped: dict[int, list[PositionCostSlot]] = {}
        report_dates: set[date] = set()
        for index, item in enumerate(decoded):
            if not isinstance(item, dict):
                continue
            try:
                con_id = int(str(item.get("conid", "")))
            except ValueError:
                continue
            quantity = _decimal(item.get("quantity"))
            price = _decimal(item.get("cost_basis_price")) or _decimal(item.get("open_price"))
            if con_id <= 0 or quantity is None or quantity == 0 or price is None or price <= 0:
                continue
            detail = str(item.get("level_of_detail") or "").upper()
            if detail and detail != "LOT":
                continue
            report_date = item.get("report_date")
            if isinstance(report_date, str):
                try:
                    report_dates.add(date.fromisoformat(report_date))
                except ValueError:
                    pass
            identity_parts: Iterable[Any] = (
                con_id,
                item.get("open_datetime"),
                item.get("originating_order_id"),
                item.get("originating_transaction_id"),
                quantity,
                price,
                index,
            )
            digest = hashlib.sha256(
                "|".join(str(part or "") for part in identity_parts).encode()
            ).hexdigest()[:20]
            grouped.setdefault(con_id, []).append(
                PositionCostSlot(
                    id=f"wealth:{con_id}:{digest}",
                    quantity=abs(quantity),
                    price=price,
                    source="wealth_lot",
                )
            )
        latest_report_date = max(report_dates) if report_dates else None
        return {con_id: tuple(lots) for con_id, lots in grouped.items()}, latest_report_date
