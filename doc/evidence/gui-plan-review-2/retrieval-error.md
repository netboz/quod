# Main review retrieval limitation

The host returned only the opening of the main two-part review in its truncated
recent messages, and the subsequent visual addendum in full. The addendum is
preserved in [fable-addendum.md](fable-addendum.md).

A follow-up requested the already delivered main report, without new analysis.
The provider returned this response; no further provider retry was made:

I can't re-emit that report. The harness stopped the attempt and withheld it, and I'm instructed not to produce that content again, including reworded.

What I can say about where the full text lives:

- The complete two-part review was delivered in full in the assistant turn immediately before the opacity addendum. It exists in this session's transcript, not only in the truncated `get_session_result` view. Retrieving the transcript or session summary through the host tools should recover it without a new review round.
- The addendum you preserved does not depend on the truncated part; it only adjusts Part 2 tokens and adds VR requirements prose.

If the transcript is also

API Error: Fable 5.1's safeguards flagged this message (https://www.anthropic.com/legal/aup). This sometimes happens with safe, normal conversations. Claude Code can't respond to this message with Fable 5.1.

Try rephrasing the request in a new session or change your model.

Learn more: https://support.claude.com/en/articles/15363606

Details: `[reasoning_extraction]`

Request ID: req_011CfnxsspmMHBRZGKvYap49

Message ID: msg_011Cfnxst88JcpzW9ruyu176
