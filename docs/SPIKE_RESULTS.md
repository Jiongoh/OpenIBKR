# Stage 1 read-only spike results

Status: passed

## Sanitized validation environment

- Host: Apple Silicon Mac
- IB Gateway and official TWS API: compatible 10.49 series
- Gateway endpoint: loopback-only; deployment port omitted
- API profile: dedicated read-only username; identifier omitted
- Gateway Read-Only API: enabled
- Gateway localhost-only connections: enabled
- Gateway trusted IP: `127.0.0.1` only
- API client ID: dedicated positive value; exact value omitted

## Safety verification

- Eleven automated tests pass against official `ibapi` 10.49.2.
- The complete outgoing SDK message enum is fail-closed: only the explicitly
  listed read capabilities are allowed.
- Trading messages are blocked on both the legacy and Protobuf wire paths.
- Direct calls to the two centralized wire-send entry points are blocked before
  socket access when the message is order-related.
- `placeOrder`, `cancelOrder`, global cancel, option exercise, order ID request,
  order queries and execution queries are also rejected at method entry.
- Hostnames, LAN addresses, IPv6 and client ID `0` are rejected.  The only
  permitted host is literal `127.0.0.1` with a positive client ID.
- Public results contain neither full account IDs nor financial values.

## Read-only integration verification

All validation runs connected to a manually authenticated, read-only Gateway
profile, then explicitly cancelled their read subscriptions and disconnected.
No guard violation was observed. Account type and identifiers are intentionally
not published.

### Connection and identity

- TCP and TWS API handshake: passed.
- Gateway API compatibility check: passed; exact server build omitted.
- Managed-account discovery: passed; account count and raw identifiers omitted.
  The selected identifier was held only in memory for the P&L request and was
  not persisted.
- Repeated independent connect/disconnect cycles: passed.

### Account data

- Account summary end marker received: yes.
- `NetLiquidation` tag callback received: yes; value discarded.
- Position batch end marker received: yes; instruments, quantities and costs
  discarded.
- Account P&L callback received: yes.
- Daily, unrealized and realized P&L fields were numeric/finite; all three values
  were discarded rather than printed or persisted.
- Short callback-cadence sample: passed without printing financial values. No
  claim is made that an unchanged P&L value will be pushed every second.

### Market data entitlement

- `IBKR` stock contract resolution on SMART/USD: passed.
- Delayed mode: market data type `3` and actual tick callbacks received.
- Observed delayed fields: last, last size, volume, close and open.  Bid/ask were
  not observed in this short after-hours sample and must not be synthesized.
- Real-time availability is entitlement-dependent; the account-specific probe
  result is intentionally omitted from this repository.
- Regulatory snapshots were disabled, so the fee-bearing per-snapshot path was
  never requested.

## Feasibility conclusion

The core architecture in `HANDOFF.md` is implementable with the installed
environment.  Account P&L and delayed top-of-book data work through the official
Python API. Real-time quote availability depends on the deployment's
entitlements and does not block an MVP that clearly labels the returned data
type.

### Gateway restart and subscription recovery

- Gateway was manually exited and reopened while the reconnect probe remained
  alive in the same Python process.
- Gateway displayed `API Client Disconnect` when the old socket was closed.
  This was expected and did not represent an order or account error.
- The probe observed the initial connection closing and recovered using bounded
  exponential backoff; the deployment-specific retry count is omitted.
- Account summary, positions, account P&L and delayed market data subscriptions
  were all restored without restarting the Python process.
- Gateway connectivity state changes were observed and recovery completed; the
  deployment-specific state sequence is omitted.
- No wire-guard violation occurred, and no order-related request was sent.
- After verification the probe cancelled its read subscriptions and exited.
  A socket check showed only Gateway listening on the configured loopback port,
  with no remaining API client connection.

All Stage 1 acceptance criteria are now satisfied for the generic read-only
Gateway deployment profile.
