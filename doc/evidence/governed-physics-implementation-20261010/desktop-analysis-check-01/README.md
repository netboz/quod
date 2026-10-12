# Movement report regression check

The new report computes its verdict from measured criteria and the recorded child exit; it no longer embeds the previous recording's prose. Reanalysis uses the unmodified inputs from desktop-262-02, not a new browser session.

Campaign01 also rejected body identity because its new assertion mistakenly expected numeric IDs. The existing protocol represents IDs as decimal strings. Campaign02 corrects only that wire-type assumption and rejects exactly the expected conditions: the three held-input pauses above100ms and the native occupied-floor refusals. It passes the unchanged body/fence, capture, visibility, renewal and completion checks. Exit1 is the expected historical rejection, not new feature acceptance.

Raw inputs remain in the committed desktop-262-02 evidence. The next actual recording has a separate campaign and requires all acceptance checks to pass.
