# Authenticated receiver selection in existing owners

The existing signed HUD socket is the live client owner. Register its exact
verified human identity and a random connection token only while an authorized
HUD projection is installed. The token survives refresh on that same socket;
the registration does not survive invalidation, expiry, identity changes or
disconnect. Renewal reuses the registration without writes. No global receiver
list, new process or question inventory is needed: use the existing process
registry and socket lifecycle.

The human selects node key and connection token with an ordinary signed
gui_select_receiver/3 call in their own ontology. Shared HUD behavior owns this
single replaceable selection. It is routing intent, not proof of presence.
A stale selection must be checked against its exact native host, never replaced
by an arbitrary connection found in the registry. Agent-originated discovery
requires the human ontology's authored gui_receiver_policy/2 permission; the
human can always discover their own selected receiver.

The client uses the existing signed-operation journal for selection. An unresolved
selection blocks another automatic selection from that client; it is not retried.
An unchanged signed HUD renewal does not select again. Connection identity and
selection are independent of form drafts and of accepted question lifetime.

This slice supplies selection/authenticated connection identity, not presentation
acceptance. Native preparation must still obtain exact installed agent feasibility,
client descriptor acceptance and expiry, through the existing action/effect path.
No ordinary live-observation query is made sealable by this change.
