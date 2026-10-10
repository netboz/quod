# Read-only access probe: no signed baseline established

On October 10 the MCP browser listed no open tool sessions. A new read-only
Explorer probe at the candidate endpoint `https://192.168.1.10:31609/explorer/`
returned `chrome-error://chromewebdata/`. It was closed without accessing an
identity store or signing a request. An empty tool session list does not establish
whether Yan has an existing personal lobby or signed session elsewhere.

The presented public certificate names `localhost` and `127.0.0.1`, not
`192.168.1.10`. The direct address failed hostname verification. A later plain
curl check of `https://localhost:31609/explorer/` found no local listener. A
connection to the candidate IP while retaining `localhost` as the TLS name
failed certificate verification with a self-signed-certificate error (exit 60).
No verification bypass, browser storage change, account creation, live ledger
write, tunnel or server reconfiguration was performed.

The previous MCP WebGL2 fixture is only local client evidence. The actual signed
personal-lobby identity, current history and desktop collision acceptance remain
unverified. The refound owner's root and system-vocabulary anchors do not supply
that missing personal identity.
