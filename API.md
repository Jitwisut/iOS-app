# AppleHome Light Server API

AppleHome talks to your own hardware in one of two shapes, chosen under
**Settings › Light server (API) › Kind**:

- **One on/off device** — a single device with fixed endpoints, e.g. an ESP32 relay.
  See [One on/off device](#one-onoff-device) below.
- **Server with many lights** — a server that lists several lights and supports
  brightness. That is the REST contract documented in the rest of this file.

---

## One on/off device

Default paths, all configurable in the app:

```
POST {base}/api/on       -> {"on": true}
POST {base}/api/off      -> {"on": false}
GET  {base}/api/status   -> {"on": true}
```

- **Address**: e.g. `http://192.168.1.46`
- **Auth**: the API key is sent in a header you choose, `X-API-Key` by default.
  Reply `401` to reject it.
- The reply to every call should include the resulting state; the app reads
  `on`, `state`, `power` or `status`, accepting `true/false`, `1/0` or `"on"/"off"`.
- Brightness is not used in this mode; the light shows as simply on or off.

Verified against an ESP device with:

```bash
curl -i -X POST -H "X-API-Key: <key>" "http://192.168.1.46/api/on"
```

Arrival automation calls `POST /api/on` when you enter your zone, and `POST /api/off`
when you leave (if that option is on). A failed call is retried once after a second,
because these devices often drop the first connection after idling.

---

## Server with many lights

Set it up in the app under **Settings › Light server (API)**.

- **Base URL**: e.g. `https://home.example.com/api` or `http://192.168.1.50:8080`
  (plain `http://` is only allowed for local-network addresses).
- **Auth** (optional): if you enter a token, every request carries
  `Authorization: Bearer <token>`. Reply `401` or `403` to reject it.
- All bodies are JSON (`Content-Type: application/json`).

## Light object

| Field        | Type    | Required | Notes                                                                 |
|--------------|---------|----------|-----------------------------------------------------------------------|
| `id`         | string  | yes      | Stable and unique. Arrival settings refer to lights by this id.       |
| `name`       | string  | yes      | Shown on the light card.                                              |
| `room`       | string  | no       | Groups lights into rooms (and into the 3D house). Defaults to "Other". |
| `on`         | boolean | yes      |                                                                       |
| `brightness` | integer | no       | `0`–`100`. Leave it out for on/off-only lights.                       |
| `type`       | string  | no       | Icon hint: `bulb`, `ceiling`, `floorLamp`, `tableLamp`, `strip`, `outdoor`. |

## `GET {base}/lights`

Returns every light, either as a bare array or wrapped in `{ "lights": [...] }`.

```json
[
  { "id": "living-1", "name": "Ceiling Light", "room": "Living Room", "on": true, "brightness": 80, "type": "ceiling" },
  { "id": "porch-1", "name": "Porch Light", "room": "Porch", "on": false }
]
```

## `PATCH {base}/lights/{id}`

Changes one light. Both fields are optional; apply whichever are present.

```json
{ "on": true, "brightness": 65 }
```

Reply `2xx` on success (the updated light object is a good body, but the app ignores it).
Any other status is shown to the user as an error.

## Arrival behaviour

When you enter the arrival zone, iOS wakes AppleHome in the background for a few
seconds and it sends `PATCH /lights/{id}` with `{"on": true}` for each selected light
(and `{"on": false}` on leaving, if enabled). Keep responses fast (well under 5 s) so
the calls finish before iOS suspends the app again.

## Try it with the mock server

```bash
python3 mock-server/server.py
```

Then set the Server URL to `http://localhost:8787` in the Simulator, or
`http://<your-mac-ip>:8787` on an iPhone on the same Wi-Fi.
